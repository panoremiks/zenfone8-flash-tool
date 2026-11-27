#!/usr/bin/env bash
#
# flash-rom.sh
# Install an A/B (dynamic-partition) ROM on ASUS_I006D / sake, with a vbmeta
# signed by our own AVB key.
#
# Approach:
#   - no `dd` on partitions; everything goes through `fastboot`,
#   - physical partitions (vbmeta, vbmeta_system, boot, dtbo, vendor_boot)
#     are flashed in the bootloader,
#   - logical partitions (system, system_ext, vendor, product, odm)
#     are flashed through fastbootd (keeps the existing super layout),
#   - vbmeta: our RSA-2048 key, flags=3 (verification disabled), rollback index 0,
#   - the AVB key pair is used ONLY to sign vbmeta; avb_custom_key is not
#     written (it may already be registered in RPMB).
#
# The script is ROM-agnostic for A/B dynamic-partition packages:
#   - images can come from a payload-based OTA ZIP (payload.bin),
#   - or from a ZIP containing plain .img files,
#   - or already be extracted in the images directory,
#   - the partition list is auto-detected and missing partitions are skipped.
#
# Usage:
#   ./flash-rom.sh                        # plan + confirmation prompt
#   ./flash-rom.sh --yes                  # no prompt
#   ./flash-rom.sh --dry-run              # print commands only
#   ./flash-rom.sh --detect               # report state only, then exit
#   ./flash-rom.sh --zip FILE.zip         # ROM package (default: bundled one)
#   ./flash-rom.sh --images-dir DIR       # where images live / are extracted
#   ./flash-rom.sh --logical "system vendor product"
#   ./flash-rom.sh --no-extract           # never extract
#   ./flash-rom.sh --no-wipe              # keep userdata/metadata
#   ./flash-rom.sh --gen-keys             # create the AVB key pair if missing
#   ./flash-rom.sh --register-key         # write the public key to avb_custom_key and exit
#   ./flash-rom.sh --serial SERIAL        # select device
#   ./flash-rom.sh --super-image FILE.img # flash one sparse super
#
# Wipe runs in the bootloader (`erase metadata` + `format userdata`), because
# fastbootd has no wipe task for these partitions on this device.
# The script never deletes files on the host.
#
set -euo pipefail

# ============================================================================
# 1. Paths - everything relative to this script's directory
# ============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

WORK_DIR="$SCRIPT_DIR"                                # images (overridable)
KEYS_DIR="$SCRIPT_DIR/keys"                           # AVB key pair
ZIP_FILE="$SCRIPT_DIR/lineage-18.1-20230220-UNOFFICIAL-sake.zip"

PRIVATE_KEY="$KEYS_DIR/avb_test_private.pem"
PUBLIC_KEY="$KEYS_DIR/avb_test_public.bin"

PHYSICAL_STR="boot dtbo vendor_boot vbmeta vbmeta_system"
LOGICAL_STR="system system_ext vendor product odm"

# ============================================================================
# 2. Options
# ============================================================================

DRY_RUN=0
ASSUME_YES=0
DO_WIPE=1
GEN_KEYS=0
REGISTER_KEY=0
DETECT_ONLY=0
NO_EXTRACT=0
SERIAL=""
SUPER_IMAGE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y)      ASSUME_YES=1 ;;
        --dry-run|-n)  DRY_RUN=1 ;;
        --no-wipe)     DO_WIPE=0 ;;
        --wipe)        DO_WIPE=1 ;;
        --gen-keys)    GEN_KEYS=1 ;;
        --register-key) REGISTER_KEY=1 ;;
        --detect)      DETECT_ONLY=1 ;;
        --no-extract)  NO_EXTRACT=1 ;;
        --zip)         ZIP_FILE="${2:?missing value for --zip}"; shift ;;
        --images|--images-dir)  WORK_DIR="${2:?missing value for --images-dir}"; shift ;;
        --keys)        KEYS_DIR="${2:?missing value for --keys}"; shift ;;
        --logical)     LOGICAL_STR="${2:?missing value for --logical}"; shift ;;
        --serial)      SERIAL="${2:?missing value for --serial}"; shift ;;
        --super-image) SUPER_IMAGE="${2:?missing value for --super-image}"; shift ;;
        -h|--help)     awk '/^# flash-rom/{f=1} /^set -euo/{exit} f' "$0"; exit 0 ;;
        *)             echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

PRIVATE_KEY="$KEYS_DIR/avb_test_private.pem"
PUBLIC_KEY="$KEYS_DIR/avb_test_public.bin"
VBMETA_OUT="$WORK_DIR/vbmeta_custom_flags3.img"

# With --super-image there is no per-partition system flashing.
if [ -n "$SUPER_IMAGE" ]; then
    LOGICAL_STR=""
fi

# ============================================================================
# 3. Helpers
# ============================================================================

say() {
    echo
    echo "--- $* ---"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

fastboot_cmd() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY-RUN: fastboot $*"
    else
        fastboot "$@"
    fi
}

# All partition names currently in scope (physical + logical).
image_bases() {
    echo "$PHYSICAL_STR $LOGICAL_STR"
}

# Names whose .img file is missing in WORK_DIR.
missing_images() {
    for name in $(image_bases); do
        [ -f "$WORK_DIR/$name.img" ] || echo "$name"
    done
}

# True when payload.bin is available locally or inside the ZIP.
payload_available() {
    [ -f "$WORK_DIR/payload.bin" ] && return 0
    if [ -f "$ZIP_FILE" ] && unzip -l "$ZIP_FILE" 2>/dev/null | grep -q 'payload\.bin'; then
        return 0
    fi
    return 1
}

# True when the ZIP contains plain .img entries.
zip_has_images() {
    [ -f "$ZIP_FILE" ] || return 1
    unzip -l "$ZIP_FILE" 2>/dev/null | awk '{print $4}' | grep -qE '\.img$'
}

# Partition names listed in the payload manifest (no protoc required).
payload_partitions() {
    python3 - "$1" <<'PY'
import struct
import sys


def read_varint(buf, i):
    value = 0
    shift = 0
    while True:
        byte = buf[i]
        i += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, i
        shift += 7


def fields(buf):
    i = 0
    out = []
    while i < len(buf):
        key, i = read_varint(buf, i)
        number = key >> 3
        wire = key & 7
        if wire == 0:
            value, i = read_varint(buf, i)
            out.append((number, value if isinstance(value, bytes) else None))
        elif wire == 2:
            length, i = read_varint(buf, i)
            out.append((number, buf[i:i + length]))
            i += length
        elif wire == 5:
            i += 4
        elif wire == 1:
            i += 8
        else:
            break
    return out


with open(sys.argv[1], 'rb') as handle:
    header = handle.read(24)
    if header[:4] != b'CrAU':
        sys.exit('not a payload file')
    # Android payload header is big-endian: magic[4], version[8],
    # manifest_size[8], signature_size[4].
    manifest_size = struct.unpack_from('>Q', header, 12)[0]
    handle.seek(24)
    manifest = handle.read(manifest_size)

for number, value in fields(manifest):
    if number == 13:  # partitions
        for sub_number, sub_value in fields(value):
            if sub_number == 1:  # partition_name
                print(sub_value.decode())
PY
}

# Keeps only names present in the available list (newline separated).
filter_names() {
    local wanted="$1"
    local available="$2"
    local result=""
    local name
    for name in $wanted; do
        if printf '%s\n' "$available" | grep -qx "$name"; then
            result="$result $name"
        fi
    done
    echo "${result# }"
}

# Prints what we have and what has to happen next.
show_state() {
    local present=0
    local total=0
    local missing

    for name in $(image_bases); do
        total=$((total + 1))
        [ -f "$WORK_DIR/$name.img" ] && present=$((present + 1))
    done
    missing="$(missing_images | tr '\n' ' ')"

    say "State"
    echo "images dir : $WORK_DIR"
    echo "package    : $ZIP_FILE"
    echo "images     : $present/$total present"
    [ -n "$missing" ] && echo "missing    : $missing"
    if payload_available; then
        echo "payload    : available"
    elif zip_has_images; then
        echo "payload    : absent, ZIP has plain .img files"
    else
        echo "payload    : not available"
    fi

    if [ "$present" -eq "$total" ] && [ "$total" -gt 0 ]; then
        echo "state      : IMAGES READY - only vbmeta signing and flashing needed"
    elif payload_available || zip_has_images; then
        echo "state      : EXTRACTION NEEDED"
    else
        echo "state      : INCOMPLETE - missing images and no package data"
    fi
}

# --detect: report and stop (no device required, nothing changed).
if [ "$DETECT_ONLY" -eq 1 ]; then
    show_state
    exit 0
fi

# ============================================================================
# 4. Preflight
# ============================================================================

say "Preflight"

command -v fastboot >/dev/null || die "fastboot is not installed"
command -v avbtool  >/dev/null || die "avbtool is not installed"

if [ "$GEN_KEYS" -eq 1 ]; then
    say "Generating AVB key pair"
    mkdir -p "$KEYS_DIR"
    if [ -f "$PRIVATE_KEY" ] && [ -f "$PUBLIC_KEY" ]; then
        echo "key already exists: $PRIVATE_KEY"
    elif [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY-RUN: openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out $PRIVATE_KEY"
        echo "DRY-RUN: avbtool extract_public_key --key $PRIVATE_KEY --output $PUBLIC_KEY"
    else
        command -v openssl >/dev/null || die "openssl is not installed"
        [ -f "$PRIVATE_KEY" ] || ( umask 077 && openssl genpkey -algorithm RSA \
            -pkeyopt rsa_keygen_bits:2048 -out "$PRIVATE_KEY" )
        [ -f "$PUBLIC_KEY" ] || avbtool extract_public_key --key "$PRIVATE_KEY" --output "$PUBLIC_KEY"
        echo "public key sha256: $(sha256sum "$PUBLIC_KEY" | awk '{print $1}')"
    fi
    echo "AVB key pair ready in $KEYS_DIR"
    exit 0
fi

[ -f "$PRIVATE_KEY" ] || [ "$DRY_RUN" -eq 1 ] || die "missing private key: $PRIVATE_KEY"
[ -f "$PUBLIC_KEY"  ] || [ "$DRY_RUN" -eq 1 ] || die "missing public key: $PUBLIC_KEY"

if [ -z "$SERIAL" ]; then
    SERIAL="$(fastboot devices | awk 'NR==1{print $1}')"
fi
[ -n "$SERIAL" ] || die "no device found in fastboot mode"
echo "device: $SERIAL"

if [ "$DRY_RUN" -eq 0 ]; then
    IS_USERSPACE="$(fastboot -s "$SERIAL" getvar is-userspace 2>&1 | sed -n 's/^is-userspace: *//p')"
    [ "$IS_USERSPACE" != "yes" ] || die "device is in fastbootd; phase 1 requires the bootloader"
fi

# --register-key is a standalone action: write the public key and exit.
if [ "$REGISTER_KEY" -eq 1 ]; then
    say "Registering avb_custom_key"
    fastboot_cmd -s "$SERIAL" flash avb_custom_key "$PUBLIC_KEY"
    echo "avb_custom_key updated"
    exit 0
fi

# ============================================================================
# 5. Images - detect what we have, extract only what is missing
# ============================================================================

say "Images"
show_state

if [ -n "$(missing_images)" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY-RUN: some images are missing; extraction would be attempted"
    elif [ "$NO_EXTRACT" -eq 1 ]; then
        die "images are missing and --no-extract was given"
    elif payload_available; then
        FREE_KB="$(df -Pk "$WORK_DIR" | awk 'NR==2{print $4}')"
        [ "${FREE_KB:-0}" -ge 9000000 ] || die "not enough space in $WORK_DIR (need ~9 GB)"

        DUMPER="${PAYLOAD_DUMPER:-}"
        if [ -z "$DUMPER" ]; then
            for candidate in \
                "$WORK_DIR/tools/payload_dumper" \
                "$(command -v payload_dumper 2>/dev/null || true)" \
                "$HOME/.local/bin/payload_dumper" \
                "$HOME/.local/venvs/payload_dumper/bin/payload_dumper"
            do
                if [ -n "$candidate" ] && [ -x "$candidate" ]; then
                    DUMPER="$candidate"
                    break
                fi
            done
        fi
        [ -n "$DUMPER" ] || die "payload_dumper not found (python3 -m pip install --user payload_dumper)"

        mkdir -p "$WORK_DIR"
        if [ ! -f "$WORK_DIR/payload.bin" ]; then
            echo "extracting payload.bin from $ZIP_FILE"
            unzip -o -q "$ZIP_FILE" payload.bin payload_properties.txt -d "$WORK_DIR"
        fi

        AVAILABLE="$(payload_partitions "$WORK_DIR/payload.bin")"
        [ -n "$AVAILABLE" ] || die "could not read partition list from payload.bin"

        PHYSICAL_STR="$(filter_names "$PHYSICAL_STR" "$AVAILABLE")"
        LOGICAL_STR="$(filter_names "$LOGICAL_STR" "$AVAILABLE")"
        echo "partitions in payload: $(echo $AVAILABLE | tr '\n' ' ')"

        echo "extracting partition images into $WORK_DIR"
        "$DUMPER" --out "$WORK_DIR" "$WORK_DIR/payload.bin"

    elif zip_has_images; then
        mkdir -p "$WORK_DIR"
        echo "extracting .img files from $ZIP_FILE"
        unzip -o -q -j "$ZIP_FILE" '*.img' -d "$WORK_DIR"

        AVAILABLE="$(ls "$WORK_DIR" | sed -n 's/\.img$//p')"
        PHYSICAL_STR="$(filter_names "$PHYSICAL_STR" "$AVAILABLE")"
        LOGICAL_STR="$(filter_names "$LOGICAL_STR" "$AVAILABLE")"
    else
        die "images missing and no payload.bin or .img files available"
    fi
else
    echo "all images already present - skipping extraction"
fi

# Drop optional partitions that are missing; boot and vbmeta are mandatory.
FINAL_PHYSICAL=""
for name in $PHYSICAL_STR; do
    if [ -f "$WORK_DIR/$name.img" ]; then
        FINAL_PHYSICAL="$FINAL_PHYSICAL $name"
    elif [ "$name" = "boot" ] || [ "$name" = "vbmeta" ]; then
        [ "$DRY_RUN" -eq 1 ] || die "required image missing: $WORK_DIR/$name.img"
        FINAL_PHYSICAL="$FINAL_PHYSICAL $name"
    else
        echo "WARNING: $WORK_DIR/$name.img missing - skipping '$name'"
    fi
done
PHYSICAL_STR="${FINAL_PHYSICAL# }"

FINAL_LOGICAL=""
for name in $LOGICAL_STR; do
    if [ -f "$WORK_DIR/$name.img" ]; then
        FINAL_LOGICAL="$FINAL_LOGICAL $name"
    else
        echo "WARNING: $WORK_DIR/$name.img missing - skipping '$name'"
    fi
done
LOGICAL_STR="${FINAL_LOGICAL# }"

echo "physical partitions: ${PHYSICAL_STR:-none}"
echo "logical partitions : ${LOGICAL_STR:-none}"

# ============================================================================
# 6. Build vbmeta signed with our key
# ============================================================================

say "Building vbmeta (our key, flags=3, rollback=0)"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY-RUN: avbtool make_vbmeta_image --key $PRIVATE_KEY ... --output $VBMETA_OUT"
else
    avbtool make_vbmeta_image \
        --key "$PRIVATE_KEY" \
        --algorithm SHA256_RSA2048 \
        --flags 3 \
        --rollback_index 0 \
        --include_descriptors_from_image "$WORK_DIR/vbmeta.img" \
        --output "$VBMETA_OUT"

    avbtool info_image --image "$VBMETA_OUT" | grep -E "Public key|Algorithm|Flags|Rollback Index"
fi

# ============================================================================
# 7. Plan
# ============================================================================

say "Plan"

echo "Phase 1 (bootloader fastboot):"
echo "  flash vbmeta          $VBMETA_OUT"
for name in $PHYSICAL_STR; do
    [ "$name" = "vbmeta" ] && continue
    echo "  flash $name"
done

echo
echo "Wipe (bootloader):"
if [ "$DO_WIPE" -eq 1 ]; then
    echo "  erase metadata + format userdata"
else
    echo "  (skipped: --no-wipe)"
fi

echo
echo "Phase 2 (system):"
if [ -n "$SUPER_IMAGE" ]; then
    echo "  flash super           $SUPER_IMAGE"
else
    echo "  reboot to fastbootd, then flash: ${LOGICAL_STR:-none}"
fi

# ============================================================================
# 8. Phase 1 - vbmeta and key registration
# ============================================================================

say "Phase 1: vbmeta"

fastboot_cmd -s "$SERIAL" flash vbmeta "$VBMETA_OUT"

say "Phase 1: remaining physical partitions"
for name in $PHYSICAL_STR; do
    [ "$name" = "vbmeta" ] && continue
    fastboot_cmd -s "$SERIAL" flash "$name" "$WORK_DIR/$name.img"
done

# ============================================================================
# 9. Wipe - bootloader only (fastbootd has no wipe task for these)
# ============================================================================

if [ "$DO_WIPE" -eq 1 ]; then
    say "Wipe userdata/metadata (bootloader)"

    fastboot_cmd -s "$SERIAL" erase metadata || \
        echo "WARNING: erase metadata failed"

    fastboot_cmd -s "$SERIAL" format userdata || \
        echo "WARNING: format userdata failed"
fi

# ============================================================================
# 10. Phase 2 - system
# ============================================================================

say "Phase 2: system"

if [ -n "$SUPER_IMAGE" ]; then
    [ -f "$SUPER_IMAGE" ] || die "missing super image: $SUPER_IMAGE"
    fastboot_cmd -s "$SERIAL" flash super "$SUPER_IMAGE"
else
    fastboot_cmd -s "$SERIAL" reboot fastboot

    if [ "$DRY_RUN" -eq 0 ]; then
        echo "waiting for fastbootd..."
        READY=0
        for _ in $(seq 1 30); do
            sleep 3
            MODE="$(fastboot -s "$SERIAL" getvar is-userspace 2>&1 | sed -n 's/^is-userspace: *//p')"
            if [ "$MODE" = "yes" ]; then
                READY=1
                break
            fi
        done
        [ "$READY" -eq 1 ] || die "fastbootd did not start; use --super-image with a sparse super"

        for name in $LOGICAL_STR; do
            fastboot_cmd -s "$SERIAL" flash "$name" "$WORK_DIR/$name.img"
        done
    else
        for name in $LOGICAL_STR; do
            fastboot_cmd -s "$SERIAL" flash "$name" "$WORK_DIR/$name.img"
        done
    fi
fi

# ============================================================================
# 11. Reboot
# ============================================================================

say "Reboot"
fastboot_cmd -s "$SERIAL" reboot

echo
echo "Done. The first boot can take 5-15 minutes."
echo "To return to stock, flash the official ASUS firmware package with fastboot."
