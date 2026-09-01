# Minimal OpenWrt package for geo2txt (marked as arch: all)

include $(TOPDIR)/rules.mk

PKG_NAME:=geo2txt
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_ARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/geo2txt
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=geo2txt - simple geo to text helper
  URL:=https://example.com/geo2txt
endef

define Package/geo2txt/description
Simple geo2txt helper script used by luci-app-mosdns to provide geo lookups.
endef

define Build/Compile
  true
endef

define Package/geo2txt/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/geo2txt.sh $(1)/usr/bin/geo2txt
endef

$(eval $(call BuildPackage,geo2txt))
