#!/bin/bash
# re-ss-01-nowifi: 打源码补丁, RE-SS-01 (京东云亚瑟 AX1800 Pro) 纯上游无 WiFi 构建
# 作用 1: 移除固件里的全部 WiFi 组件
# 背景: WiFi 包在 Kconfig 里是 select 强制选中, 只改 .config 关不掉, 必须动源码
# 移除三处:
#   1. target/linux/qualcommax/Makefile       DEFAULT_PACKAGES: 只删 token kmod-ath11k-ahb / wpad-basic-mbedtls
#      注意: kmod-ath11k-ahb 与 kmod-qca-nss-dp 同行, 必须 token 级删除, 整行删会挂有线网
#   2. target/linux/qualcommax/ipq60xx/target.mk  DEFAULT_PACKAGES: ath11k-firmware-ipq6018
#   3. target/linux/qualcommax/image/ipq60xx.mk   Device/jdcloud_re-ss-01: ipq-wifi-jdcloud_re-ss-01
# 传递依赖 (kmod-ath11k / kmod-mac80211 / kmod-cfg80211 / iw / wireless-regdb / hostapd-common)
# 在根包移除后自动落选, 由工作流的 defconfig 硬检查兜底确认
# 作用 2 (唯一 diy): 默认 LAN IP 192.168.1.1 -> 192.168.100.1, 与 honk 版 diy-part2 同款改法
# 作用 3: ucode ubus 请求原型泄漏 backport (fanchmwrt issue #48)
#         ucode < 2026-09-10 每次_ubus_请求泄漏 ~4.2KB (netifd 实测 ~36MB/天), OOM 后
#         odhcp6c 孤儿占住 ubus 对象名, wan_6 (IPv6) 永久失效。补入上游
#         c404fe2d + fbdd169e; 26.11/openwrt-main (pin dfc64d41) 已含修复, 按日期自动跳过
# 工作流调用位置: openwrt/ 目录下 (feeds install 之后、make defconfig 之前)
set -e

TMK=target/linux/qualcommax/Makefile
TSUB=target/linux/qualcommax/ipq60xx/target.mk
IMK=target/linux/qualcommax/image/ipq60xx.mk
CG=package/base-files/files/bin/config_generate

die() { echo "ERROR: $1" >&2; exit 1; }

# ===== 1. qualcommax target 默认包 =====
[ "$(grep -c 'kmod-ath11k-ahb' $TMK)" = "1" ] || die "$TMK 里 kmod-ath11k-ahb 行数异常 (上游结构变了?)"
# 只删 kmod-ath11k-ahb 这个 token, 保留同行的 kmod-qca-nss-dp (6.12 有线网卡 MAC 驱动)!
# 整行删除会把 nss-dp 一起删掉 → eth 口完全消失 → 绿灯但客户端拿不到 IP (已踩坑)
# 6.18 (26.08/26.11) 结构不同: kmod-ath11k-ahb 独占一行, 且无 nss-dp (网卡走内核 EDMA),
# 故先整行删独占行, 再对同行共享行做 token 级删除; NSS 校验按原文件是否含 nss-dp 条件化
HADNSS=$(grep -c 'kmod-qca-nss-dp' $TMK || true)
sed -i -E '/^[[:space:]]*kmod-ath11k-ahb[[:space:]]*\\[[:space:]]*$/d' $TMK
sed -i -E 's/[[:space:]]+kmod-ath11k-ahb//g' $TMK
if [ "$HADNSS" -gt 0 ] && ! grep -q 'kmod-qca-nss-dp' $TMK; then
	die "kmod-qca-nss-dp 意外丢失, 有线网会挂"
fi

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

# ===== 5. ucode ubus 请求原型泄漏 backport (fanchmwrt issue #48) =====
# 上游修复: c404fe2d (types: per-instance prototype support, 前置) +
#           fbdd169e (ubus: store per-call request proto in instance proto slot)
# 补丁文件在本仓库 patches/ucode/, 拷入 openwrt/package/utils/ucode/patches/ 由构建系统自动应用
UCP=package/utils/ucode
UDD=2026-09-10   # fbdd169e 合入日期: pin 源码日期晚于它视为已含修复
[ -d "$UCP" ] || die "找不到 $UCP (调用位置不对? 必须在 openwrt/ 目录下运行)"
UCDATE=$(sed -n 's/^PKG_SOURCE_DATE:=//p' $UCP/Makefile)
[ -n "$UCDATE" ] || die "无法从 $UCP/Makefile 解析 PKG_SOURCE_DATE"
if [ -f $UCP/patches/123-ubus-store-per-call-request-proto-in-instance-proto.patch ]; then
	echo "SKIP: ucode 泄漏补丁已存在 (重跑幂等)"
elif [[ "$UCDATE" < "$UDD" ]]; then
	[ -d ../patches/ucode ] || die "找不到 ../patches/ucode (本仓库补丁目录缺失?)"
	mkdir -p $UCP/patches
	for p in ../patches/ucode/122-types-add-per-instance-prototype-support.patch \
	         ../patches/ucode/123-ubus-store-per-call-request-proto-in-instance-proto.patch; do
		[ -f "$p" ] || die "补丁文件缺失: $p"
		cp -v "$p" $UCP/patches/
	done
	# 版本标识: r1 -> r2, 便于在设备上确认固件已带修复
	sed -i 's/^PKG_RELEASE:=1$/PKG_RELEASE:=2/' $UCP/Makefile
	grep -q '^PKG_RELEASE:=2$' $UCP/Makefile || die "PKG_RELEASE bump 失败"
	echo "OK: ucode ubus 泄漏 backport 就位 (pin $UCDATE < $UDD, PKG_RELEASE -> 2)"
else
	echo "SKIP: ucode pin $UCDATE >= $UDD, 源码已含上游修复, 不打补丁"
fi

# ===== 校验 (任一失败立即退出, 不浪费编译时间) =====
fail=0
if grep -qE 'kmod-ath11k|wpad' $TMK; then echo "FAIL: $TMK 仍有 wifi 包"; fail=1; else echo "OK: $TMK 已无 ath11k/wpad"; fi
if [ "$HADNSS" -gt 0 ]; then
	if grep -q 'kmod-qca-nss-dp' $TMK; then echo "OK: kmod-qca-nss-dp (有线网卡驱动) 保留"; else echo "FAIL: kmod-qca-nss-dp 丢失 → eth 口消失, 客户端拿不到 IP"; fail=1; fi
else
	echo "SKIP: 本内核线无 nss-dp (6.18 网卡走内核 EDMA, 由 CONFIG_QCOM_EDMA 提供)"
fi
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
