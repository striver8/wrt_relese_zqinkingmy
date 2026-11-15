#!/usr/bin/env bash
# install_feeds 前的 feed 工作树修正。

remove_unwanted_packages() {
    # 移除将由 custom_feed 接管或会产生冲突的上游包。
    local luci_packages=(
        "luci-app-passwall" "luci-app-ddns-go" "luci-app-rclone" "luci-app-ssr-plus"
        "luci-app-vssr" "luci-app-daed" "luci-app-dae" "luci-app-alist" "luci-app-homeproxy"
        "luci-app-haproxy-tcp" "luci-app-openclash" "luci-app-mihomo" "luci-app-appfilter"
        "luci-app-msd_lite" "luci-app-unblockneteasemusic" "luci-app-adguardhome"
    )
    local packages_net=(
        "haproxy" "xray-core" "xray-plugin" "dns2socks" "alist" "hysteria"
        "mosdns" "adguardhome" "ddns-go" "naiveproxy" "shadowsocks-rust"
        "sing-box" "v2ray-core" "v2ray-geodata" "v2ray-plugin" "tuic-client"
        "chinadns-ng" "ipt2socks" "tcping" "trojan-plus" "simple-obfs" "shadowsocksr-libev"
        "dae" "daed" "mihomo" "geoview" "open-app-filter" "msd_lite"
    )
    local packages_utils=(
        "cups"
    )
    for pkg in "${luci_packages[@]}"; do
        if [[ -d ./feeds/luci/applications/$pkg ]]; then
            \rm -rf ./feeds/luci/applications/$pkg
        fi
        if [[ -d ./feeds/luci/themes/$pkg ]]; then
            \rm -rf ./feeds/luci/themes/$pkg
        fi
    done

    for pkg in "${packages_net[@]}"; do
        if [[ -d ./feeds/packages/net/$pkg ]]; then
            \rm -rf ./feeds/packages/net/$pkg
        fi
    done

    for pkg in "${packages_utils[@]}"; do
        if [[ -d ./feeds/packages/utils/$pkg ]]; then
            \rm -rf ./feeds/packages/utils/$pkg
        fi
    done

    if [[ -d ./package/istore ]]; then
        \rm -rf ./package/istore
    fi

    if [ -d "$BUILD_DIR/target/linux/qualcommax/base-files/etc/uci-defaults" ]; then
        find "$BUILD_DIR/target/linux/qualcommax/base-files/etc/uci-defaults/" -type f -name "99*.sh" -exec rm -f {} +
    fi
}


fix_libxcrypt_werror() {
    # openwrt-24.10 的 feeds/packages/libs/libxcrypt（4.4.36）默认把告警当错误处理，
    # 与 musl 的 fortify 头冲突：staging 的 include/fortify/stdio.h 用
    # __builtin_va_arg_pack 包装 snprintf/sprintf，编译 lib/gen-des-tables.c 时
    # 会报 -Werror=format-nonliteral 并中断，表现为
    #   make[5]: *** [Makefile:1915: lib/gen-des-tables.o] Error 1
    # shadow 依赖 libxcrypt，因此选中 shadow 的设备（如 supergateway_s20m_immwrt）会失败。
    # 该包自带 --disable-werror 开关，打开即可，不影响其它包。
    local mk_paths=(
        "$BUILD_DIR/feeds/packages/libs/libxcrypt/Makefile"
        "$BUILD_DIR/package/feeds/packages/libxcrypt/Makefile"
    )
    local mk_path

    for mk_path in "${mk_paths[@]}"; do
        [ -f "$mk_path" ] || continue

        if grep -q -- "--disable-werror" "$mk_path"; then
            continue
        fi

        if ! grep -q "^CONFIGURE_ARGS" "$mk_path"; then
            continue
        fi

        # 尽量插在 BuildPackage 之前，保持文件结构可读。
        sed -i '/^\$(eval \$(call BuildPackage/i CONFIGURE_ARGS += --disable-werror' "$mk_path"
        if ! grep -q -- "--disable-werror" "$mk_path"; then
            printf '\nCONFIGURE_ARGS += --disable-werror\n' >>"$mk_path"
        fi

        echo "已为 libxcrypt 关闭 -Werror（规避 musl fortify 的 -Wformat-nonliteral）：$mk_path"
    done
}

fix_containerd_cpuid_linkname() {
    # containerd 1.7.22 的 vendor/github.com/klauspost/cpuid/v2（v2.0.4）用
    # //go:linkname 引用 runtime.sched_getaffinity 统计 CPU 数，也 linkname 到
    # internal/cpu.HWCap 读硬件能力位。Go 1.23 起链接器禁止引用 runtime/内部符号，
    # arm64 目标链接 ctr 时直接失败：
    #   link: github.com/klauspost/cpuid/v2: invalid reference to runtime.sched_getaffinity
    #   make[4]: *** [Makefile:257: bin/ctr] Error 1
    #   ERROR: package/feeds/packages/containerd failed to build.
    # 上游 cpuid 后续版本已把 getproccount 改成 runtime.NumCPU()。这里在 prepare 之后
    # 对 vendor 文件做等价替换：去掉 sched_getaffinity 的 linkname 与声明，getproccount
    # 改用 runtime.NumCPU()；同时去掉 hwcap 的 linkname，让 detectOS 走它自带的
    # /proc/self/auxv 回退分支（拿到的 HWCAP 值一致）。
    # 注意：该包自带的 build_dir 会在 configure 阶段被拷进 .go_work/build/src，
    # 所以钩子必须挂在 Prepare 之后、Configure 之前。
    local pkg_dirs=(
        "$BUILD_DIR/feeds/packages/utils/containerd"
        "$BUILD_DIR/package/feeds/packages/containerd"
    )
    local dir

    for dir in "${pkg_dirs[@]}"; do
        [ -f "$dir/Makefile" ] || continue

        if grep -q "ContainerdPatchCpuidLinkname" "$dir/Makefile"; then
            continue
        fi

        mkdir -p "$dir/files"
        cat >"$dir/files/fix-cpuid-linkname.sh" <<'SCRIPT'
#!/bin/sh
# 用法：fix-cpuid-linkname.sh <os_linux_arm64.go>
# 把 cpuid v2.0.4 里依赖 //go:linkname 引用 runtime 内部符号的实现，换成上游
# 后续版本的做法（runtime.NumCPU()），规避 Go 1.23+ 链接器的
# "invalid reference to runtime.sched_getaffinity"。已处理过或文件不存在时直接跳过。
set -e

f="$1"
[ -f "$f" ] || exit 0
grep -q 'go:linkname sched_getaffinity' "$f" || exit 0

tmp="$f.cpuidfix.$$"
awk '
{ L[NR] = $0 }
END {
	for (i = 1; i <= NR; i++) {
		if (L[i] == "//go:noescape" && L[i + 1] ~ /^\/\/go:linkname sched_getaffinity/) continue
		if (L[i] ~ /^\/\/go:linkname sched_getaffinity/) continue
		if (L[i] ~ /^\/\/go:linkname hwcap /) continue
		if (L[i] ~ /^func sched_getaffinity\(/) continue
		if (L[i] ~ /^func getproccount\(\) int32 \{$/) {
			print "func getproccount() int32 {"
			print "\treturn int32(runtime.NumCPU())"
			print "}"
			skip = 1
			continue
		}
		if (skip) {
			if (L[i] == "}") skip = 0
			continue
		}
		print L[i]
	}
}
' "$f" >"$tmp"

# 替换后文件里可能不再引用 unsafe，此时删掉该 import，避免 unused import 报错。
if ! grep -q 'unsafe\.' "$tmp"; then
	sed -i '/^[[:space:]]*"unsafe"[[:space:]]*$/d' "$tmp"
fi

mv "$tmp" "$f"
SCRIPT
        chmod 0755 "$dir/files/fix-cpuid-linkname.sh"

        # 钩子必须在 $(eval $(call BuildPackage,...)) 之前注册：BuildPackage 展开时
        # 会把 Hooks/Prepare/Post 就地展开成具体命令，之后再注册就无效了。
        awk '
            index($0, "$(eval $(call BuildPackage") == 1 && !inserted {
                print "# Go 1.23+ 的链接器不允许 cpuid v2.0.4 通过 //go:linkname 引用 runtime"
                print "# 内部符号（runtime.sched_getaffinity / internal/cpu.HWCap），containerd"
                print "# 的 ctr 会链接失败；在 prepare 之后、configure 拷贝源码到 .go_work 之前替换。"
                print "define ContainerdPatchCpuidLinkname"
                print "sh $(CURDIR)/files/fix-cpuid-linkname.sh \"$(PKG_BUILD_DIR)/vendor/github.com/klauspost/cpuid/v2/os_linux_arm64.go\""
                print "endef"
                print "Hooks/Prepare/Post += ContainerdPatchCpuidLinkname"
                inserted = 1
            }
            { print }
        ' "$dir/Makefile" >"$dir/Makefile.tmp"
        mv -f "$dir/Makefile.tmp" "$dir/Makefile"

        if ! grep -q "ContainerdPatchCpuidLinkname" "$dir/Makefile"; then
            echo "警告：未在 $dir/Makefile 中找到 BuildPackage 行，cpuid 补丁钩子未注册。" >&2
            continue
        fi

        echo "已为 containerd 打上 cpuid linkname 兼容补丁（Go 1.23+）：$dir/Makefile"
    done
}


update_homeproxy() {
    local repo_url="https://github.com/xchxtom/luci-app-homeproxy.git"
    local target_dir="$(get_custom_feed_worktree_dir)/luci-app-homeproxy"

    if [ -d "$target_dir" ]; then
        echo "正在从 xchxtom 仓库更新 homeproxy..."
        rm -rf "$target_dir"
        if ! git clone --depth 1 "$repo_url" "$target_dir"; then
            echo "错误：从 $repo_url 克隆 homeproxy 仓库失败" >&2
            exit 1
        fi
    fi
}

file_sha256_hex() {
    # sha256sum 在含特殊字符的路径下会给输出加反斜杠前缀（\0 在 sed 替换串里代表整个匹配），
    # 这里统一清洗成纯小写十六进制，避免污染 Makefile。
    sha256sum "$1" | awk '{print $1}' | tr -d '\\' | tr 'A-Z' 'a-z'
}


update_singbox() {
    # 需要锁定的 sing-box 版本；改版本只需改这里。
    local target_version="1.14.4"
    local target_dir="$(get_custom_feed_worktree_dir)/sing-box"
    local tarball_name="sing-box-${target_version}.tar.gz"
    local dl_dir="$BUILD_DIR/dl"
    local tarball_urls=(
        "https://codeload.github.com/SagerNet/sing-box/tar.gz/v${target_version}"
        "https://github.com/SagerNet/sing-box/archive/refs/tags/v${target_version}.tar.gz"
        "https://ghproxy.net/https://github.com/SagerNet/sing-box/archive/refs/tags/v${target_version}.tar.gz"
    )
    local mk_path
    local version_var=""
    local tmp_tarball
    local pkg_hash=""
    local url

    # 容错：如果 feeds 体系尚未完全展开，尝试去本地源源目录寻找
    if [ ! -d "$target_dir" ]; then
        target_dir="$(get_custom_feed_source_dir)/sing-box"
    fi

    if [ ! -d "$target_dir" ]; then
        echo "警告：未找到 sing-box 源码目录，跳过版本锁定。" >&2
        return 0
    fi

    mk_path="$target_dir/Makefile"
    if [ ! -f "$mk_path" ]; then
        echo "警告：sing-box Makefile 不存在：$mk_path，跳过版本锁定。" >&2
        return 0
    fi

    # 上游在不同时期用 PKG_UPSTREAM_VERSION / PKG_VERSION 承载版本号。
    # 新版 Makefile 里 PKG_VERSION 由 PKG_UPSTREAM_VERSION 派生（含 $(subst ...)），
    # 只改写字面量版本行，否则会把派生表达式替换成固定值，导致
    # PKG_SOURCE 与 PKG_HASH 指向不同版本而下载 404。
    if grep -qE '^PKG_UPSTREAM_VERSION:=[0-9]' "$mk_path"; then
        version_var="PKG_UPSTREAM_VERSION"
    elif grep -qE '^PKG_VERSION:=[0-9]' "$mk_path"; then
        version_var="PKG_VERSION"
    fi

    if [ -z "$version_var" ]; then
        echo "警告：$mk_path 中未找到可改写的版本变量，跳过版本锁定。" >&2
        return 0
    fi

    echo "正在将 sing-box 锁定编译为 ${target_version} 版本..."

    # 1. 先把源码包落地到 dl/，build 阶段直接命中本地缓存，
    #    不再依赖 codeload 在构建时的可用性（历史构建多次在此 404）。
    mkdir -p "$dl_dir"
    if [ -f "$dl_dir/$tarball_name" ]; then
        pkg_hash=$(file_sha256_hex "$dl_dir/$tarball_name")
        echo "dl 目录已有 $tarball_name，直接复用。"
    else
        tmp_tarball=$(mktemp)
        for url in "${tarball_urls[@]}"; do
            echo "正在下载 sing-box v${target_version} 源码包：$url"
            if curl -fsSL --connect-timeout 15 --max-time 300 --retry 3 --retry-delay 5 \
                -o "$tmp_tarball" "$url"; then
                pkg_hash=$(file_sha256_hex "$tmp_tarball")
                mv "$tmp_tarball" "$dl_dir/$tarball_name"
                break
            fi
            echo "下载失败，尝试下一个镜像。" >&2
        done
        rm -f "$tmp_tarball"
    fi

    if [ -z "$pkg_hash" ]; then
        echo "警告：sing-box v${target_version} 源码包获取失败，保持上游版本与校验值不变。" >&2
        return 0
    fi

    if ! [[ $pkg_hash =~ ^[0-9a-f]{64}$ ]]; then
        echo "错误：sing-box v${target_version} 校验值异常（$pkg_hash），保持上游版本与校验值不变。" >&2
        return 1
    fi

    # 2. 版本号与校验值同时改写，保证 PKG_SOURCE、PKG_BUILD_DIR、PKG_HASH 三者一致。
    sed -i "s|^${version_var}:=.*|${version_var}:=${target_version}|" "$mk_path"
    sed -i "s|^PKG_HASH:=.*|PKG_HASH:=${pkg_hash}|" "$mk_path"

    if ! grep -qE "^${version_var}:=${target_version}$" "$mk_path"; then
        echo "错误：未能改写 $mk_path 的 ${version_var}，sing-box 版本锁定失败。" >&2
        exit 1
    fi

    echo "sing-box 已锁定至 ${target_version}，源码包已就绪：$dl_dir/$tarball_name"
}

update_lucky() {
    local lucky_repo_url="https://github.com/gdy666/luci-app-lucky.git"
    local target_custom_feed_dir="$(get_custom_feed_worktree_dir)"
    local lucky_dir="$target_custom_feed_dir/lucky"
    local luci_app_lucky_dir="$target_custom_feed_dir/luci-app-lucky"

    if [ ! -d "$lucky_dir" ] || [ ! -d "$luci_app_lucky_dir" ]; then
        echo "Warning: $lucky_dir 或 $luci_app_lucky_dir 不存在，跳过 lucky 源代码更新。" >&2
    else
        local tmp_dir
        tmp_dir=$(mktemp -d)

        echo "正在从 $lucky_repo_url 稀疏检出 luci-app-lucky 和 lucky..."

        if ! git_retry clone --depth 1 --filter=blob:none --no-checkout "$lucky_repo_url" "$tmp_dir"; then
            echo "错误：从 $lucky_repo_url 克隆仓库失败" >&2
            rm -rf "$tmp_dir"
            return 0
        fi

        pushd "$tmp_dir" >/dev/null
        git_retry sparse-checkout init --cone
        git_retry sparse-checkout set luci-app-lucky lucky || {
            echo "错误：稀疏检出 luci-app-lucky 或 lucky 失败" >&2
            popd >/dev/null
            rm -rf "$tmp_dir"
            return 0
        }
        git_retry checkout --quiet

        \cp -rf "$tmp_dir/luci-app-lucky/." "$luci_app_lucky_dir/"
        \cp -rf "$tmp_dir/lucky/." "$lucky_dir/"

        popd >/dev/null
        rm -rf "$tmp_dir"
        echo "luci-app-lucky 和 lucky 源代码更新完成。"
    fi

    local lucky_conf="$(get_custom_feed_worktree_dir)/lucky/files/luckyuci"
    if [ -f "$lucky_conf" ]; then
        sed -i "s/option enabled '1'/option enabled '0'/g" "$lucky_conf"
        sed -i "s/option logger '1'/option logger '0'/g" "$lucky_conf"
    fi

    local version
    version=$(find "$BASE_PATH/patches" -name "lucky_*.tar.gz" -printf "%f\n" | head -n 1 | sed -n 's/^lucky_\(.*\)_Linux.*$/\1/p')
    if [ -z "$version" ]; then
        echo "Warning: 未找到 lucky 补丁文件，跳过更新。" >&2
        return 0
    fi

    local makefile_path="$(get_custom_feed_worktree_dir)/lucky/Makefile"
    if [ ! -f "$makefile_path" ]; then
        echo "Warning: lucky Makefile not found. Skipping." >&2
        return 0
    fi

    echo "正在更新 lucky Makefile..."
    local patch_line="\\t[ -f \$(TOPDIR)/../wrt_core/patches/lucky_${version}_Linux_\$(LUCKY_ARCH)_wanji.tar.gz ] && install -Dm644 \$(TOPDIR)/../wrt_core/patches/lucky_${version}_Linux_\$(LUCKY_ARCH)_wanji.tar.gz \$(DL_DIR)/\$(PKG_SOURCE)"

    if grep -q "Build/Prepare" "$makefile_path"; then
        sed -i "/Build\\/Prepare/a\\$patch_line" "$makefile_path"
        sed -i '/wget/d' "$makefile_path"
        echo "lucky Makefile 更新完成。"
    else
        echo "Warning: lucky Makefile 中未找到 'Build/Prepare'。跳过。" >&2
    fi
}


remove_attendedsysupgrade() {
    find "$BUILD_DIR/feeds/luci/collections" -name "Makefile" | while read -r makefile; do
        if grep -q "luci-app-attendedsysupgrade" "$makefile"; then
            sed -i "/luci-app-attendedsysupgrade/d" "$makefile"
            echo "Removed luci-app-attendedsysupgrade from $makefile"
        fi
    done
}


fix_mkpkg_format_invalid() {
    local custom_feed_worktree_dir
    custom_feed_worktree_dir=$(get_custom_feed_worktree_dir)

    if [[ $BUILD_DIR =~ "imm-nss" ]]; then
        if [ -f "$custom_feed_worktree_dir/v2ray-geodata/Makefile" ]; then
            sed -i 's/VER)-\$(PKG_RELEASE)/VER)-r\$(PKG_RELEASE)/g' "$custom_feed_worktree_dir/v2ray-geodata/Makefile"
        fi
        if [ -f "$custom_feed_worktree_dir/luci-lib-taskd/Makefile" ]; then
            sed -i 's/>=1\.0\.3-1/>=1\.0\.3-r1/g' "$custom_feed_worktree_dir/luci-lib-taskd/Makefile"
        fi
        if [ -f "$custom_feed_worktree_dir/luci-app-openclash/Makefile" ]; then
            sed -i 's/PKG_RELEASE:=beta/PKG_RELEASE:=1/g' "$custom_feed_worktree_dir/luci-app-openclash/Makefile"
        fi
        if [ -f "$custom_feed_worktree_dir/luci-app-quickstart/Makefile" ]; then
            sed -i 's/PKG_VERSION:=0\.8\.16-1/PKG_VERSION:=0\.8\.16/g' "$custom_feed_worktree_dir/luci-app-quickstart/Makefile"
            sed -i 's/PKG_RELEASE:=$/PKG_RELEASE:=1/g' "$custom_feed_worktree_dir/luci-app-quickstart/Makefile"
        fi
        if [ -f "$custom_feed_worktree_dir/luci-app-store/Makefile" ]; then
            sed -i 's/PKG_VERSION:=0\.1\.27-1/PKG_VERSION:=0\.1\.27/g' "$custom_feed_worktree_dir/luci-app-store/Makefile"
            sed -i 's/PKG_RELEASE:=$/PKG_RELEASE:=1/g' "$custom_feed_worktree_dir/luci-app-store/Makefile"
        fi
    fi
}


update_tcping() {
    local tcping_path="$(get_custom_feed_worktree_dir)/tcping/Makefile"
    local url="https://raw.githubusercontent.com/Openwrt-Passwall/openwrt-passwall-packages/refs/heads/main/tcping/Makefile"

    if [ -d "$(dirname "$tcping_path")" ]; then
        echo "正在更新 tcping Makefile..."
        if ! curl_retry -fsSL -o "$tcping_path" "$url"; then
            echo "错误：从 $url 下载 tcping Makefile 失败" >&2
            exit 1
        fi
    fi
}


apply_passwall_smartdns_patch() {
    local package_dir="$(get_custom_feed_worktree_dir)/luci-app-passwall"
    local patch_files=(
        "$BASE_PATH/patches/passwall-smartdns-custom-conf.patch"
        "$BASE_PATH/patches/passwall-smartdns-ui-cleanup.patch"
        "$BASE_PATH/patches/passwall-smartdns-runtime.patch"
        "$BASE_PATH/patches/passwall-smartdns-loop-guard.patch"
    )
    local patch_file

    if [ ! -d "$package_dir" ]; then
        echo "错误：未找到 luci-app-passwall 源码目录：$package_dir" >&2
        return 1
    fi

    for patch_file in "${patch_files[@]}"; do
        if [ ! -f "$patch_file" ]; then
            echo "错误：未找到 Passwall patch：$patch_file" >&2
            return 1
        fi
        if ! (cd "$package_dir" && patch --dry-run --batch --fuzz=0 -p1 < "$patch_file" >/dev/null); then
            echo "错误：Passwall patch 无法应用，可能是上游源码已变化：$patch_file" >&2
            return 1
        fi
        if ! (cd "$package_dir" && patch --batch --fuzz=0 -p1 < "$patch_file" >/dev/null); then
            echo "错误：应用 Passwall patch 失败：$patch_file" >&2
            return 1
        fi
    done
    echo "已应用 Passwall SmartDNS custom.conf、UI cleanup、runtime 和 loop guard patch。"
}


apply_passwall_tweaks() {
    apply_passwall_smartdns_patch || return 1

    local chnlist_path="$(get_custom_feed_worktree_dir)/luci-app-passwall/root/usr/share/passwall/rules/chnlist"
    if [ -f "$chnlist_path" ]; then
        >"$chnlist_path"
    fi

    local xray_util_path="$(get_custom_feed_worktree_dir)/luci-app-passwall/luasrc/passwall/util_xray.lua"
    if [ -f "$xray_util_path" ]; then
        sed -i 's/maxRTT = "1s"/maxRTT = "2s"/g' "$xray_util_path"
        sed -i 's/sampling = 3/sampling = 5/g' "$xray_util_path"
    fi
}


update_mosdns_deconfig() {
    local mosdns_conf="$(get_custom_feed_worktree_dir)/luci-app-mosdns/root/etc/config/mosdns"
    if [ -d "${mosdns_conf%/*}" ] && [ -f "$mosdns_conf" ]; then
        sed -i 's/8000/300/g' "$mosdns_conf"
        sed -i 's/5335/5336/g' "$mosdns_conf"
    fi
}


fix_quickstart() {
    local file_path="$(get_custom_feed_worktree_dir)/luci-app-quickstart/luasrc/controller/istore_backend.lua"
    local makefile_path="$(get_custom_feed_worktree_dir)/quickstart/Makefile"
    local url="https://gist.githubusercontent.com/puteulanus/1c180fae6bccd25e57eb6d30b7aa28aa/raw/istore_backend.lua"
    if [ -f "$file_path" ]; then
        echo "正在修复 quickstart..."
        if ! curl_retry -fsSL -o "$file_path" "$url"; then
            echo "错误：从 $url 下载 istore_backend.lua 失败" >&2
            exit 1
        fi
    fi

    if [ -f "$makefile_path" ]; then
        echo "正在移除 quickstart 非必要存储依赖..."
        sed -i \
            -e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+smartmontools-drivedb//g' \
            -e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+smartmontools//g' \
            -e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+mdadm//g' \
            -e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+parted//g' \
            -e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+e2fsprogs//g' \
            "$makefile_path"
    fi
}


update_oaf_deconfig() {
    local init_path="$(get_custom_feed_worktree_dir)/open-app-filter/files/appfilter.init"

    if [ -f "$init_path" ]; then
        sed -i \
            -e '/config appfilter appfilter/,/config macfilter macfilter/ s/option enable 1/option enable 0/' \
            -e '/config macfilter macfilter/,/config record / s/option enable 1/option enable 0/' \
            -e "/config record 'record'/,/config network network/ s/option enable '1'/option enable '0'/" \
            "$init_path"

        sed -i \
            -e '/^[[:space:]]*ensure_default_configs$/a\
\tif [ "$(uci -q get fwx.appfilter.enable)" != "1" ] && [ "$(uci -q get fwx.macfilter.enable)" != "1" ] && [ "$(uci -q get fwx.record.enable)" != "1" ]; then' \
            -e '/^[[:space:]]*ensure_default_configs$/a\
\t\treturn 0' \
            -e '/^[[:space:]]*ensure_default_configs$/a\
\tfi' \
            "$init_path"
    fi
}


fix_easytier_mk() {
    local mk_path="$(get_custom_feed_worktree_dir)/luci-app-easytier/easytier/Makefile"
    if [ -f "$mk_path" ]; then
        sed -i 's/!@(mips||mipsel)/!TARGET_mips \&\& !TARGET_mipsel/g' "$mk_path"
    fi
}


remove_tweaked_packages() {
    local target_mk="$BUILD_DIR/include/target.mk"
    if [ -f "$target_mk" ]; then
        if grep -q "^DEFAULT_PACKAGES += \$(DEFAULT_PACKAGES.tweak)" "$target_mk"; then
            sed -i 's/DEFAULT_PACKAGES += $(DEFAULT_PACKAGES.tweak)/# DEFAULT_PACKAGES += $(DEFAULT_PACKAGES.tweak)/g' "$target_mk"
        fi
    fi
}
