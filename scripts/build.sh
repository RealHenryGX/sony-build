#!/usr/bin/env bash
# Gravity_Ext — Sony tama (apollo / akari) 4.9 kernel build.
#
# 前提：内核树自证完整 —— KernelSU 与 SUSFS 都以提交形式在树里。
# 本脚本不做任何源码级 patch，只做「配置 → 编译 → 重打包 → 自证」。
set -euo pipefail

KERNEL_DIR="${KERNEL_DIR:-kernel}"
DEFCONFIG="${DEFCONFIG:?DEFCONFIG required}"
EXPECT_RELEASE="${EXPECT_RELEASE:?EXPECT_RELEASE required}"
DEVICE="${DEVICE:?DEVICE required}"
STOCK_BOOT_URL="${STOCK_BOOT_URL:?STOCK_BOOT_URL required}"
EXPECT_KSU_VERSION="${EXPECT_KSU_VERSION:-11872}"
CMDLINE="${CMDLINE:-androidboot.hardware=qcom video=vfb:640x400,bpp=32,memsize=3072000 msm_rtb.filter=0x237 ehci-hcd.park=3 lpm_levels.sleep_disabled=1 service_locator.enable=1 swiotlb=2048 androidboot.configfs=true loop.max_part=7 androidboot.usbcontroller=a600000.dwc3 panic_on_err=1 msm_drm.dsi_display0=dsi_panel_cmd_display:config0 buildvariant=userdebug}"
OUT="${OUT:-$PWD/out}"
DIST="${DIST:-$PWD/dist}"
JOBS="${JOBS:-$(nproc --all)}"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { echo "FATAL: $*" >&2; exit 1; }
step() { echo; echo "==== $* ===="; }

export ARCH=arm64
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-gravity}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-gravity-ext}"
export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-$(date)}"
export LC_ALL=C

# shim 必须在 cd 之前算（$OUT 后面会被清空）
SHIM="${SHIM:-$PWD/toolshim}"

cd "$KERNEL_DIR"

step "1/8 交叉工具链 shim（工具链里的裸 ld/ar 会抢宿主 gcc，必须隔离）"
TOOLBIN="${TOOLBIN:-$(dirname "$(command -v clang)")}"
TOOLBIN="$(cd "$TOOLBIN" && pwd)"
[ -x "$TOOLBIN/clang" ] || die "找不到 clang（TOOLBIN=$TOOLBIN）"
rm -rf "$SHIM"; mkdir -p "$SHIM"
for t in clang clang++ lld ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf llvm-strip; do
    [ -x "$TOOLBIN/$t" ] && ln -sf "$TOOLBIN/$t" "$SHIM/$t"
done
for pre in aarch64-linux-gnu- arm-linux-gnueabi-; do
    for f in "$TOOLBIN/$pre"*; do
        [ -x "$f" ] && ln -sf "$f" "$SHIM/$(basename "$f")"
    done
done
# 从 PATH 里剔除原始工具链目录：只让 shim 暴露目标工具，宿主工具（ld/ar/nm）留给系统
rest=""; oIFS="$IFS"; IFS=:
for d in $PATH; do
    [ -z "$d" ] && continue
    [ "$d" = "$TOOLBIN" ] && continue
    rest="${rest:+$rest:}$d"
done
IFS="$oIFS"
export PATH="$SHIM:$rest"
command -v aarch64-linux-gnu-ld >/dev/null || die "aarch64-linux-gnu-ld 不在 PATH（shim 没搭好）"
command -v arm-linux-gnueabi-ld >/dev/null || die "arm-linux-gnueabi-ld 不在 PATH（shim 没搭好）"
log "clang:    $(clang --version | head -1)"
log "host ld:  $(ld --version 2>/dev/null | head -1)"
log "host gcc: $(gcc --version | head -1)"
_selftest="$(mktemp -d)"
echo 'int main(void){return 0;}' > "$_selftest/t.c"
gcc "$_selftest/t.c" -o "$_selftest/t" || die "宿主 gcc 链接失败 —— 交叉工具链污染了 PATH"
rm -rf "$_selftest"
log "宿主 gcc 链接自检通过"

step "2/8 树内自证（零构建期补丁）"
[ -f drivers/kernelsu/ksu.c ]                            || die "drivers/kernelsu/ 不在树里（KernelSU 未 vendored）"
grep -q 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile || die "drivers/Makefile 未接 kernelsu"
grep -q 'drivers/kernelsu/Kconfig'       drivers/Kconfig  || die "drivers/Kconfig 未接 kernelsu"
grep -q "DKSU_VERSION=$EXPECT_KSU_VERSION" drivers/kernelsu/Makefile \
  || die "drivers/kernelsu/Makefile 未写死 -DKSU_VERSION=$EXPECT_KSU_VERSION"
[ -f fs/susfs.c ]                              || die "fs/susfs.c 不在树里（SUSFS 未集成）"
grep -q 'susfs' fs/Makefile                    || die "fs/Makefile 未接 susfs"
grep -q 'SUSFS_VERSION' include/linux/susfs.h  || die "include/linux/susfs.h 缺失"
log "susfs: $(grep -m1 'SUSFS_VERSION' include/linux/susfs.h)"
[ -f "arch/arm64/configs/$DEFCONFIG" ] || die "defconfig arch/arm64/configs/$DEFCONFIG 不存在"
log "defconfig sha256: $(sha256sum "arch/arm64/configs/$DEFCONFIG" | cut -d' ' -f1)"
grep -n 'CONFIG_LOCALVERSION=' "arch/arm64/configs/$DEFCONFIG"

step "3/8 生成配置"
REUSE=0
if [ "${SKIP_BUILD:-0}" = "1" ] && [ -f "$OUT/arch/arm64/boot/Image.gz-dtb" ] && [ -f "$OUT/.config" ]; then
    REUSE=1
    log "SKIP_BUILD=1：复用已有 $OUT（配置 + 产物），跳过配置与编译 —— 仅用于迭代调试"
else
    rm -rf "$OUT"; mkdir -p "$OUT"
    make -j"$JOBS" O="$OUT" ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-linux-gnu- \
         CROSS_COMPILE_ARM32=arm-linux-gnueabi- "$DEFCONFIG" >/dev/null
    cp "$OUT/.config" "$OUT/final.config"   # upload-artifact 会跳过 .config 这种隐藏名
fi

step "4/8 resolved config 断言"
# 只断言 KSU 真正需要的符号（v0.9.5 源码里只 #ifdef CONFIG_KPROBES）。
# 注意：CONFIG_KPROBE_EVENTS 是 4.14+ 的名字，4.9 树上叫 CONFIG_KPROBE_EVENT；
# 名字写错会被 kconfig 当未知符号静默丢弃，所以断言必须落在 resolved .config 上。
for k in CONFIG_KSU CONFIG_KPROBES CONFIG_KALLSYMS CONFIG_KSU_SUSFS CONFIG_IKCONFIG_PROC CONFIG_MODULES; do
    grep -q "^$k=y" "$OUT/.config" || die "$k 未出现在 resolved .config（被 Kconfig 静默丢弃？）"
done
grep -E "^CONFIG_(KSU|KSU_SUSFS|LOCALVERSION)=" "$OUT/.config"

step "5/8 release 串契约"
# include/config/kernel.release 只在真正编译时才生成，所以这里用 make kernelrelease 取值。
RELEASE_RAW="$(make -s O="$OUT" ARCH=arm64 kernelrelease 2>/dev/null | tail -1)"
[ -n "$RELEASE_RAW" ] || die "make kernelrelease 取不到值"
RELEASE="${RELEASE_RAW%+}"
log "kernel release = $RELEASE_RAW"
[ "$RELEASE" = "$EXPECT_RELEASE" ] || die "release 不是 $EXPECT_RELEASE（实际 $RELEASE_RAW）"
case "$RELEASE" in *ksu*|*susfs*|*KSU*|*SUSFS*) die "release 串含检测敏感词：$RELEASE" ;; esac
case "$RELEASE" in *-g[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) die "release 串含 -g<hash>：$RELEASE" ;; esac

step "6/8 编译 Image.gz-dtb（流式日志）"
LOG="$OUT/build.log"
if [ "$REUSE" = "1" ]; then
    log "SKIP_BUILD=1：跳过编译（复用 $OUT/arch/arm64/boot/Image.gz-dtb）"
else
make -j"$JOBS" O="$OUT" ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-linux-gnu- \
     CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
     KCFLAGS+=-Wno-error=implicit-function-declaration \
     KCFLAGS+=-Wno-error=implicit-int \
     KCFLAGS+=-Wno-error=incompatible-function-pointer-types \
     KCFLAGS+=-Wno-error=deprecated-non-prototype \
     KCFLAGS+=-Wno-error=array-bounds \
     KCFLAGS+=-Wno-error=pointer-bool-conversion \
     KCFLAGS+=-Wno-error=string-plus-int \
     KCFLAGS+=-Wno-error=sizeof-array-div \
     KCFLAGS+=-Wno-error=tautological-compare \
     KCFLAGS+=-Wno-error=deprecated-declarations \
     KCFLAGS+=-Wno-error=strict-prototypes \
     KCFLAGS+=-Wno-error=date-time \
     Image.gz-dtb 2>&1 | tee "$LOG" | awk '
       /error:|Error [0-9]|undefined reference|FAILED/ { print "!! " $0 }
       { n++; if (n % 2000 == 0) print "[progress] " n " 行日志…" }
       END { print "[log] 合计 " n " 行" }'
fi
KIMG="$OUT/arch/arm64/boot/Image.gz-dtb"
[ -f "$KIMG" ] || { grep -nE 'error:|undefined reference' "$LOG" | head -40; die "Image.gz-dtb 未产出"; }
log "Image.gz-dtb = $(stat -c%s "$KIMG") 字节"

# 编译后 kernel.release 文件应已生成，且必须与前面的契约一致
RELFILE="$OUT/include/config/kernel.release"
[ -f "$RELFILE" ] || die "编译后仍无 include/config/kernel.release"
[ "$(cat "$RELFILE")" = "$RELEASE_RAW" ] || die "kernel.release 文件($(cat "$RELFILE")) 与 kernelrelease($RELEASE_RAW) 不一致"
log "kernel.release 文件一致：$(cat "$RELFILE")"

step "7/8 产物自证（KSU/SUSFS 真的编进内核了吗）"
mkdir -p "$OUT/verify"
python3 - "$KIMG" "$OUT/verify/Image" <<'PY'
import os, sys, zlib
raw = open(sys.argv[1], 'rb').read()
# 这棵树的 Image.gz-dtb = Image.gz（单个 gzip 成员）+ 多个 dtb(FDT) 拼接。
# Python 的 gzip 模块按规范会继续找下一个成员，碰到尾部的 dtb 就 BadGzipFile；
# zlib.decompressobj(31) 只解第一个 gzip 流，剩余部分留在 unused_data。
d = zlib.decompressobj(31)
img = d.decompress(raw)
tail = d.unused_data
assert not d.unconsumed_tail, "第一个 gzip 流没解干净"
assert tail[:4] == b'\xd0\x0d\xfe\xed', f"追加数据不是 FDT 开头：{tail[:4]!r}"
plain = os.path.join(os.path.dirname(sys.argv[1]), 'Image')
open(sys.argv[2], 'wb').write(img)
if os.path.exists(plain):
    same = os.path.getsize(plain) == len(img)
    print(f"[verify] 与同目录未压缩 Image 对照：{'一致' if same else '不一致(!!)'} ({os.path.getsize(plain)} vs {len(img)})")
print(f"[verify] Image.gz-dtb {len(raw)} = gzip({len(img)}) + 追加 {len(tail)} 字节（dtb 链）")
PY
VIMG="$OUT/verify/Image"
hit() { c=$(grep -ac -- "$1" "$VIMG" 2>/dev/null || true); [ "${c:-0}" -gt 0 ] || die "解压 Image 里找不到: $1"; log "命中 $1 = $c"; }
hit susfs
hit KERNEL_ZYGOTE_DOMAIN
hit kernelsu
hit ksu_handle
strings -a "$VIMG" | grep -m1 'Linux version'

step "8/8 重打包 boot.img（原厂 ramdisk + 原 header 参数）"
# 全部在 $OUT/repack 里做，避免往内核树里拉东西（本地跑时尤其重要）
REPACK="$OUT/repack"
rm -rf "$REPACK"; mkdir -p "$REPACK" "$DIST"
cd "$REPACK"
BOOTIMG="$DIST/boot-${RELEASE}.img"
wget -q "$STOCK_BOOT_URL" -O stock_boot.img || die "stock boot 下载失败"
git clone -q --depth 1 https://github.com/LineageOS/android_system_tools_mkbootimg mkbootimg-tools
python3 mkbootimg-tools/unpack_bootimg.py --boot_img stock_boot.img --out stock_unpack >/dev/null
K_PARTS=$(python3 - <<'PY'
import struct
d = open('stock_boot.img', 'rb').read()
print(struct.unpack('<I', d[8:12])[0], struct.unpack('<I', d[16:20])[0], struct.unpack('<I', d[40:44])[0])
PY
)
set -- $K_PARTS
log "stock boot: kernel_size=$1 ramdisk_size=$2 header_v=$3"
[ "$3" -ge 1 ]  || die "stock boot header_version=$3（预期 v1）"
[ "$2" -gt 5000000 ] || die "stock ramdisk 太小（$2）—— 解包不对"

python3 mkbootimg-tools/mkbootimg.py \
  --kernel "$KIMG" \
  --ramdisk stock_unpack/ramdisk \
  --base 0x0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 --tags_offset 0x100 \
  --pagesize 4096 --header_version 1 \
  --os_version 13.0.0 --os_patch_level 2023-09 \
  --cmdline "$CMDLINE" \
  --output "$BOOTIMG"
python3 - "$BOOTIMG" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
ks = struct.unpack('<I', d[8:12])[0]
rs = struct.unpack('<I', d[16:20])[0]
hv = struct.unpack('<I', d[40:44])[0]
print(f"boot.img: {len(d)} 字节 kernel={ks} ramdisk={rs} header_v={hv}")
assert d[:8] == b'ANDROID!' and ks > 10000000 and rs > 5000000 and hv >= 1, "boot.img 结构异常"
PY

cp "$OUT/final.config" "$DIST/"
sha256sum "$BOOTIMG" | tee "$BOOTIMG.sha256"
echo "$RELEASE" > "$DIST/release.txt"
echo "$DEVICE" > "$DIST/device.txt"
ls -l "$DIST"
log "构建完成：$RELEASE ($DEVICE)"
log "  镜像: $BOOTIMG"
log "  内核: $KIMG ($(stat -c%s "$KIMG") 字节)"
