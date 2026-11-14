#!/usr/bin/env bash
# LuCI 展示、菜单和前端相关修正。

set_build_signature() {
    local file="$BUILD_DIR/feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js"
    if [ -d "$(dirname "$file")" ] && [ -f $file ]; then
        sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ build by ZqinKing')/g" "$file"
    fi
}

update_menu_location() {
    local samba4_path="$BUILD_DIR/feeds/luci/applications/luci-app-samba4/root/usr/share/luci/menu.d/luci-app-samba4.json"
    if [ -d "$(dirname "$samba4_path")" ] && [ -f "$samba4_path" ]; then
        sed -i 's/nas/services/g' "$samba4_path"
    fi

    local tailscale_path="$(get_custom_feed_worktree_dir)/luci-app-tailscale/root/usr/share/luci/menu.d/luci-app-tailscale.json"
    if [ -d "$(dirname "$tailscale_path")" ] && [ -f "$tailscale_path" ]; then
        sed -i 's/services/vpn/g' "$tailscale_path"
    fi
}


update_nginx_ubus_module() {
    local makefile_path="$BUILD_DIR/feeds/packages/net/nginx/Makefile"
    local source_date="2024-03-02"
    local source_version="564fa3e9c2b04ea298ea659b793480415da26415"
    local mirror_hash="92c9ab94d88a2fe8d7d1e8a15d15cfc4d529fdc357ed96d22b65d5da3dd24d7f"

    if [ -f "$makefile_path" ]; then
        sed -i "s/SOURCE_DATE:=2020-09-06/SOURCE_DATE:=$source_date/g" "$makefile_path"
        sed -i "s/SOURCE_VERSION:=b2d7260dcb428b2fb65540edb28d7538602b4a26/SOURCE_VERSION:=$source_version/g" "$makefile_path"
        sed -i "s/MIRROR_HASH:=515bb9d355ad80916f594046a45c190a68fb6554d6795a54ca15cab8bdd12fda/MIRROR_HASH:=$mirror_hash/g" "$makefile_path"
        echo "已更新 nginx-mod-ubus 模块的 SOURCE_DATE, SOURCE_VERSION 和 MIRROR_HASH。"
    else
        echo "错误：未找到 $makefile_path 文件，无法更新 nginx-mod-ubus 模块。" >&2
    fi
}

# 兜底主题守卫：每次开机校验 luci.main.mediaurlbase 指向的主题目录与 ucode 模板
# 是否真的存在，不存在则自动切换到可用主题。
# 背景：/etc/uci-defaults/30_luci-theme-* 只在首次启动执行一次，sysupgrade
# 保留配置升级（LuCI 升级页默认勾选）时不会重跑，mediaurlbase 会一直悬空，
# 表现为首页白屏/无样式并提示 "Error loading theme"。
ensure_luci_theme_guard() {
    local init_dst="$BUILD_DIR/package/base-files/files/etc/init.d/luci-theme-guard"
    local defaults_dst="$BUILD_DIR/package/base-files/files/etc/uci-defaults/993_luci-theme-guard"

    mkdir -p "$(dirname "$init_dst")" "$(dirname "$defaults_dst")"

    cat >"$init_dst" <<'EOS'
#!/bin/sh /etc/rc.common
# 保证 luci.main.mediaurlbase 指向实际存在的主题目录与 ucode 模板
START=19
STOP=89
USE_PROCD=0

start() {
	[ -d /www/luci-static ] || return 0

	cur="$(uci -q get luci.main.mediaurlbase)"
	name="${cur##*/}"

	if [ -n "$name" ] && [ -d "/www/luci-static/$name" ] && \
	   [ -d "/usr/share/ucode/luci/template/themes/$name" ]; then
		return 0
	fi

	for d in /www/luci-static/*/; do
		n="${d%/}"; n="${n##*/}"
		[ "$n" = "resources" ] && continue
		[ -d "/usr/share/ucode/luci/template/themes/$n" ] || continue
		uci set "luci.themes.$n=/luci-static/$n"
		uci set "luci.main.mediaurlbase=/luci-static/$n"
		uci commit luci
		rm -rf /tmp/luci-indexcache* /tmp/luci-sessions/*
		logger -t luci-theme-guard "mediaurlbase 修正为 /luci-static/$n (原: ${cur:-空})"
		return 0
	done

	logger -t luci-theme-guard "镜像内没有任何可用主题，LuCI 必然报错"
}
EOS

    cat >"$defaults_dst" <<'EOS'
#!/bin/sh
# 首次启动同样应用一次主题守卫，不重复实现
[ -x /etc/init.d/luci-theme-guard ] && /etc/init.d/luci-theme-guard start
exit 0
EOS

    chmod 0755 "$init_dst" "$defaults_dst"
    echo "已注入 /etc/init.d/luci-theme-guard 主题守卫。"
}
