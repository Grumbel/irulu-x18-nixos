#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later OR MIT
#
# Extract the two firmware blobs this repository needs from the tablet's
# stock Android system, and compare them with the ones in firmware/.
#
#   tools/extract-firmware.sh adb [SERIAL]    # tablet running Android, USB debugging on
#   tools/extract-firmware.sh dir SYSTEM_DIR  # a copy of Android's /system
#
# Output goes to ./firmware-extracted/ (or $OUT).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
out=${OUT:-firmware-extracted}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ko=/system/vendor/modules/gslX680new.ko
map=/system/etc/wifi/wifi_efuse_8723bs_vq0.map

case "${1:-}" in
    adb)
        adb=(adb)
        [ -n "${2:-}" ] && adb=(adb -s "$2")
        "${adb[@]}" pull "$ko" "$work/gslX680new.ko"
        "${adb[@]}" pull "$map" "$work/efuse.map"
        ;;
    dir)
        sys=${2:?usage: $0 dir SYSTEM_DIR}
        cp "$sys/vendor/modules/gslX680new.ko" "$work/gslX680new.ko"
        cp "$sys/etc/wifi/wifi_efuse_8723bs_vq0.map" "$work/efuse.map"
        ;;
    *)
        sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac

mkdir -p "$out/silead" "$out/rtl8723bs"

# Touch controller firmware: the GSL1680E_86OGS_FW array in the vendor's
# touchscreen driver. It is already in the {u32 addr, u32 val} format
# that the mainline silead driver loads.
python3 "$here/ko-extract-symbol.py" "$work/gslX680new.ko" GSL1680E_86OGS_FW \
    "$out/silead/gsl1680-irulu-x18.fw"

# Wi-Fi calibration: the logical eFuse map as hex text -> 512 byte binary,
# padded with 0xFF like an unprogrammed eFuse.
python3 - "$work/efuse.map" "$out/rtl8723bs/rtl8723bs_efuse_irulu_x18.bin" <<'EOF'
import sys
data = bytes(int(t, 16) for t in open(sys.argv[1]).read().split())
if data[:2] != b"\x29\x81":
    sys.exit("unexpected eFuse map (no 0x8129 ID)")
open(sys.argv[2], "wb").write(data + b"\xff" * (512 - len(data)))
print(f"{sys.argv[2]}: {len(data)} bytes of eFuse map")
EOF

cd "$out"
sha256sum -c <<'EOF'
7bbbe1d94b10ee6310ffc55b1c5df4d559b02f9bf006341329fc78f578b76c52  silead/gsl1680-irulu-x18.fw
ba7a7efab96afb3777239e87746e35c47778ee07cbfd89a09bd3235f6e4d757f  rtl8723bs/rtl8723bs_efuse_irulu_x18.bin
EOF
