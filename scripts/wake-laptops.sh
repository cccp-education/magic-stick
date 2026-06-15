#!/usr/bin/env bash
set -euo pipefail

VERSION="0.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<USAGE
Magic Stick Wake-on-LAN v${VERSION}

Usage: wake-laptops.sh <mac_address> [<mac_address2> ...]

Sends WoL magic packet to one or more MAC addresses.
Needs sudo for raw socket access (etherwake) or python3 fallback.

Examples:
  wake-laptops.sh aa:bb:cc:dd:ee:ff
  wake-laptops.sh aa:bb:cc:dd:ee:ff 11:22:33:44:55:66
USAGE
    exit 1
}

validate_mac() {
    local mac="$1"
    if ! echo "$mac" | grep -qiE '^([0-9a-f]{2}[:.-]?){5}[0-9a-f]{2}$'; then
        echo "[wake] ERROR: invalid MAC: $mac" >&2
        return 1
    fi
}

wake_etherwake() {
    local mac="$1"
    local iface="${2:-}"
    if [[ -n "$iface" ]]; then
        etherwake -i "$iface" "$mac"
    else
        etherwake "$mac"
    fi
}

wake_python() {
    local mac="$1"
    python3 -c "
import socket, struct, sys

mac = sys.argv[1].replace('-', ':').replace('.', ':')
mac_bytes = bytes.fromhex(mac.replace(':', ''))

# Magic packet: 6 bytes of 0xFF, then 16 repetitions of MAC
packet = b'\\xff' * 6 + mac_bytes * 16

# Send as broadcast UDP on port 9 (discard) and 7 (echo)
for port in (9, 7):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.sendto(packet, ('255.255.255.255', port))
    sock.close()
print(f'[wake] WoL sent to {mac} (ports 9, 7)')
" "$mac"
}

# --- Main ---
if [[ $# -lt 1 ]]; then
    usage
fi

# Prefer etherwake (sudo), fallback to python3
HAVE_ETHERWAKE=false
if command -v etherwake &>/dev/null; then
    HAVE_ETHERWAKE=true
fi

# Detect broadcast interface
BCAST_IFACE=""
for iface in /sys/class/net/*; do
    name=$(basename "$iface")
    [[ "$name" = "lo" ]] && continue
    state=$(cat "$iface/operstate" 2>/dev/null || echo "unknown")
    if [[ "$state" == "up" ]]; then
        BCAST_IFACE="$name"
        break
    fi
done

FAILED=0
for mac in "$@"; do
    if ! validate_mac "$mac"; then
        FAILED=$((FAILED + 1))
        continue
    fi
    if [[ "$HAVE_ETHERWAKE" == true ]]; then
        wake_etherwake "$mac" "$BCAST_IFACE"
        echo "[wake] etherwake $mac OK"
    else
        wake_python "$mac"
    fi
done

if [[ "$HAVE_ETHERWAKE" == false ]]; then
    echo "[wake] Tip: install etherwake for more reliable WoL: sudo apt install etherwake"
fi

exit $FAILED
