#!/bin/bash
# re-ss-01-nowifi: 打源码补丁, RE-SS-01 (京东云亚瑟 AX1800 Pro) 纯上游无 WiFi 构建
# 作用 1: 移除固件里的全部 WiFi 组件
# 背景: WiFi 包在 Kconfig 里是 select 强制选中, 只改 .config 关不掉, 必须动源码
# 移除三处:
#   1. target/linux/qualcommax/Makefile       DEFAULT_PACKAGES: kmod-ath11k-ahb / wpad-basic-mbedtls
#   2. target/linux/qualcommax/ipq60xx/target.mk  DEFAULT_PACKAGES: ath11k-firmware-ipq6018
#   3. target/linux/qualcommax/image/ipq60xx.mk   Device/jdcloud_re-ss-01: ipq-wifi-jdcloud_re-ss-01
# 传递依赖 (kmod-ath11k / kmod-mac80211 / kmod-cfg80211 / iw / wireless-regdb / hostapd-common)
# 在根包移除后自动落选, 由工作流的 defconfig 硬检查兜底确认
# 作用 2 (唯一 diy): 默认 LAN IP 192.168.1.1 -> 192.168.100.1, 与 honk 版 diy-part2 同款改法
# 工作流调用位置: openwrt/ 目录下 (feeds install 之后、make defconfig 之前)
set -e

TMK=target/linux/qualcommax/Makefile
TSUB=target/linux/qualcommax/ipq60xx/target.mk
IMK=target/linux/qualcommax/image/ipq60xx.mk
CG=package/base-files/files/bin/config_generate

die() { echo "ERROR: $1" >&2; exit 1; }

# ===== 1. qualcommax target 默认包 =====
[ "$(grep -c 'kmod-ath11k-ahb' $TMK)" = "1" ] || die "$TMK 里 kmod-ath11k-ahb 行数异常 (上游结构变了?)"
sed -i '/kmod-ath11k-ahb/d' $TMK

[ "$(grep -c 'wpad-basic-mbedtls' $TMK)" = "1" ] || die "$TMK 里 wpad-basic-mbedtls 行数异常 (上游结构变了?)"
# wpad 与 uboot-envtools 同一行, 只删 wpad 保留 uboot-envtools
sed -i 's/wpad-basic-mbedtls //' $TMK

# ===== 2. ipq60xx 子目标默认包 =====
[ "$(grep -c 'ath11k-firmware-ipq6018' $TSUB)" = "1" ] || die "$TSUB 里 ath11k-firmware-ipq6018 行数异常 (上游结构变了?)"
sed -i '/ath11k-firmware-ipq6018/d' $TSUB

# ===== 3. 设备定义里的校准数据包 (只动 re-ss-01 块) =====
sed -i '/^define Device\/jdcloud_re-ss-01$/,/^TARGET_DEVICES += jdcloud_re-ss-01$/s/DEVICE_PACKAGES := ipq-wifi-jdcloud_re-ss-01/DEVICE_PACKAGES :=/' $IMK

# ===== 4. 默认 LAN IP 192.168.1.1 -> 192.168.100.1 (唯一 diy) =====
[ -f "$CG" ] || die "找不到 $CG (调用位置不对? 必须在 openwrt/ 目录下运行)"
sed -i 's/192\.168\.1\.1/192.168.100.1/g' $CG
grep -q '192\.168\.100\.1' $CG || die "LAN 默认 IP 192.168.100.1 未生效"
echo "OK: LAN 默认 IP -> 192.168.100.1"

# ===== 校验 (任一失败立即退出, 不浪费编译时间) =====
fail=0
if grep -qE 'kmod-ath11k|wpad' $TMK; then echo "FAIL: $TMK 仍有 wifi 包"; fail=1; else echo "OK: $TMK 已无 ath11k/wpad"; fi
if grep -q 'ath11k' $TSUB; then echo "FAIL: $TSUB 仍有 ath11k"; fail=1; else echo "OK: $TSUB 已无 ath11k"; fi

BLK=$(sed -n '/^define Device\/jdcloud_re-ss-01$/,/^endef$/p' $IMK)
if echo "$BLK" | grep -q 'ipq-wifi'; then echo "FAIL: re-ss-01 块仍有 ipq-wifi"; fail=1; else echo "OK: re-ss-01 已无 ipq-wifi"; fi
if echo "$BLK" | grep -q 'DEVICE_PACKAGES :=$'; then echo "OK: re-ss-01 DEVICE_PACKAGES 已清空"; else echo "FAIL: re-ss-01 DEVICE_PACKAGES 未清空"; fail=1; fi

# DEFAULT_PACKAGES 完整性校验 (26.05 多 kmod-qca-nss-dp, 26.08+ 多 f2fsck/mkf2fs, 用关键字匹配)
if grep -qE '^	kmod-leds-gpio kmod-gpio-button-hotplug' $TMK; then echo "OK: led/button 行存在"; else echo "FAIL: led/button 行丢失"; fail=1; fi
if grep -q '^	uboot-envtools' $TMK; then echo "OK: uboot-envtools 行存在"; else echo "FAIL: uboot-envtools 行丢失"; fail=1; fi
if grep -qE 'e2fsprogs.*losetup$' $TMK; then echo "OK: DEFAULT_PACKAGES 末行完好"; else echo "FAIL: DEFAULT_PACKAGES 末行异常"; fail=1; fi
# 默认包末尾还有非 losetup 的 f2fs 工具行 (26.08+), 不算错

if [ "$fail" -ne 0 ]; then echo "ERROR: 去 WiFi 补丁校验失败, 请人工检查上游结构" >&2; exit 1; fi

echo "===== $TMK DEFAULT_PACKAGES (补丁后) ====="
sed -n '/^DEFAULT_PACKAGES +=/,/losetup$/p' $TMK
echo "OK: RE-SS-01 无 WiFi 补丁完成"
