#!/bin/bash
# Build a FAT32 .img from a BIOS/firmware file (e.g. an ASUS .CAP) for
# mounting as a PiKVM virtual Mass Storage Drive in "Flash" mode, so
# tools like ASUS EZ Flash 3 can see it as a USB stick.
set -euo pipefail

usage_exit() {
    cat 1>&2 <<EOF
Usage: $0 [-o output.img] [-s size_MB] [-l label] <firmware-file-or-dir>

  -o output.img   Output image path (default: <firmware-dir>/bios-flash.img)
  -s size_MB      Image size in MiB (default: firmware size + 64MB headroom,
                   rounded up to a multiple of 32, minimum 64MB)
  -l label        FAT volume label, max 11 chars (default: BIOSFLASH)
  -f              Overwrite output image if it already exists

If <firmware-file-or-dir> is a directory, the script picks the single
*.CAP/*.ROM/*.BIN file found in it (errors out if there's more than one -
pass the file directly in that case).
EOF
    exit 1
}

LABEL="BIOSFLASH"
SIZE_MB=""
OUTPUT=""
FORCE=0

while getopts "o:s:l:fh" OPT; do
    case $OPT in
        o) OUTPUT=$OPTARG ;;
        s) SIZE_MB=$OPTARG ;;
        l) LABEL=$OPTARG ;;
        f) FORCE=1 ;;
        h) usage_exit ;;
        \?) usage_exit ;;
    esac
done
shift $((OPTIND - 1))

[[ $# -eq 1 ]] || usage_exit
INPUT=$1

for bin in mkfs.vfat mcopy mdir truncate; do
    command -v "$bin" >/dev/null 2>&1 || {
        echo "error: required tool '$bin' not found (install dosfstools + mtools)" 1>&2
        exit 1
    }
done

if [[ -d $INPUT ]]; then
    mapfile -t CANDIDATES < <(find "$INPUT" -maxdepth 1 -type f \( -iname '*.cap' -o -iname '*.rom' -o -iname '*.bin' \))
    case ${#CANDIDATES[@]} in
        0) echo "error: no .CAP/.ROM/.BIN file found in $INPUT" 1>&2; exit 1 ;;
        1) FW_FILE=${CANDIDATES[0]} ;;
        *) echo "error: multiple firmware files found in $INPUT, pass one directly:" 1>&2
           printf '  %s\n' "${CANDIDATES[@]}" 1>&2
           exit 1 ;;
    esac
    FW_DIR=$INPUT
elif [[ -f $INPUT ]]; then
    FW_FILE=$INPUT
    FW_DIR=$(dirname "$INPUT")
else
    echo "error: $INPUT not found" 1>&2
    exit 1
fi

[[ -n $OUTPUT ]] || OUTPUT="$FW_DIR/bios-flash.img"

if [[ -e $OUTPUT && $FORCE -ne 1 ]]; then
    echo "error: $OUTPUT already exists (use -f to overwrite)" 1>&2
    exit 1
fi

if [[ -z $SIZE_MB ]]; then
    FW_BYTES=$(stat -c %s "$FW_FILE")
    FW_MB=$(((FW_BYTES + 1024 * 1024 - 1) / (1024 * 1024)))
    SIZE_MB=$(((FW_MB + 64 + 31) / 32 * 32))
    [[ $SIZE_MB -ge 64 ]] || SIZE_MB=64
fi

echo "Firmware file: $FW_FILE"
echo "Output image:  $OUTPUT (${SIZE_MB}MB, label ${LABEL})"

truncate -s "${SIZE_MB}M" "$OUTPUT"
mkfs.vfat -F 32 -n "$LABEL" "$OUTPUT" >/dev/null
mcopy -i "$OUTPUT" "$FW_FILE" ::

echo "--- image contents ---"
mdir -i "$OUTPUT" ::

echo
echo "Done. Upload $OUTPUT to PiKVM, mount it as a Flash (not CD) MSD image, and connect it."
