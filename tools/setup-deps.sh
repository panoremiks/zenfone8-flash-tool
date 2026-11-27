#!/usr/bin/env bash
#
# setup-deps.sh - prepare local Python dependencies and check host tools.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo "checking host tools:"
missing=0
for tool in fastboot avbtool openssl python3 unzip; do
    if command -v "$tool" >/dev/null 2>&1; then
        printf '  %-10s %s\n' "$tool" "$(command -v "$tool")"
    else
        printf '  %-10s MISSING\n' "$tool"
        missing=1
    fi
done

if [ "$missing" -ne 0 ]; then
    echo
    echo "Install the missing tools first:"
    echo "  fastboot - Android platform-tools"
    echo "  avbtool  - AOSP external/avb (python script)"
    echo "  openssl  - distribution package"
    echo "  python3 / unzip - distribution packages"
    exit 1
fi

echo
echo "creating virtualenv .venv"
python3 -m venv .venv
.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet -r requirements.txt

echo
if .venv/bin/payload_dumper --help >/dev/null 2>&1; then
    echo "payload_dumper: OK ($(.venv/bin/pip show payload_dumper | awk '/^Version:/{print $2}'))"
else
    echo "payload_dumper: FAILED"
    exit 1
fi

echo
echo "setup complete. Run: ./flash-rom.sh --detect"
