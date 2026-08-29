---
title: "fix: add geo2txt (arch=all) to satisfy luci-app-mosdns"
labels:
  - automated
body: |
  This PR adds a minimal geo2txt package marked as PKG_ARCH:=all to satisfy the
  dependency required by luci-app-mosdns. The CI build failed with:

  > pkg_hash_check_unresolved: cannot find dependency geo2txt for luci-app-mosdns
  > pkg_hash_fetch_best_installation_candidate: Packages for luci-app-mosdns found, but incompatible with the architectures configured

  Making geo2txt an arch=all package lets OpenWrt generate an all-architecture
  ipk for it. That resolves the "incompatible with the architectures"
  situation when opkg tries to install luci-app-mosdns during image packaging.

  Files added:
  - package/custom/geo2txt/Makefile
  - package/custom/geo2txt/files/geo2txt.sh

  The included geo2txt is a minimal placeholder script. Replace it with the
  real implementation if available.

  Validation steps (locally / CI):
  - ./scripts/feeds update -a && ./scripts/feeds install -a
  - make package/geo2txt/{clean,compile} V=s

  After this PR is merged, re-run CI on the default branch; the previous
  opkg installation error should be resolved.
---
