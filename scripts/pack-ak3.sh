#!/usr/bin/env bash
# 按 AnyKernel3 规范打包（格式化 anykernel.sh + tools/ 来自上游），产出到 dist/。
set -euo pipefail

IMAGE="${IMAGE:?IMAGE required}"
RELEASE="${RELEASE:?RELEASE required}"
DEVICE="${DEVICE:?DEVICE required}"
DIST="${DIST:-$PWD/dist}"
AK3_REPO="${AK3_REPO:-https://github.com/osm0sis/AnyKernel3.git}"
AK3_REF="${AK3_REF:-master}"
TEMPLATE="${TEMPLATE:-ak3/anykernel.sh}"

[ -f "$IMAGE" ] || { echo "FATAL: 没有内核镜像 $IMAGE"; exit 1; }
[ -f "$TEMPLATE" ] || { echo "FATAL: 缺少 anykernel.sh 模板 $TEMPLATE"; exit 1; }

rm -rf ak3-work
git clone -q --depth 1 -b "$AK3_REF" "$AK3_REPO" ak3-work
rm -rf ak3-work/.git ak3-work/.github ak3-work/README.md ak3-work/anykernel.sh
cp "$IMAGE" ak3-work/Image.gz-dtb
cp "$TEMPLATE" ak3-work/anykernel.sh

mkdir -p "$DIST"
ZIP="$DIST/AnyKernel3-Gravity_Ext-${RELEASE}-${DEVICE}.zip"
rm -f "$ZIP"
(cd ak3-work && zip -qr9 "$ZIP" .)
sha256sum "$ZIP" | tee "$ZIP.sha256"
echo "AK3: $(stat -c%s "$ZIP") 字节 → $ZIP"
