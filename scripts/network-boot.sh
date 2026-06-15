#!/usr/bin/env bash
set -euo pipefail

VERSION="0.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="/tmp/magic-stick-netboot"

usage() {
    cat <<USAGE
Magic Stick Network Boot Server v${VERSION}

Usage: network-boot.sh <command> [args]

Commands:
  start <iface> <http_port> <iso_path>
    Start dnsmasq (proxy DHCP + TFTP for iPXE) + Python HTTP server
    (kernel/initrd). Needs sudo. Foreground — Ctrl+C to stop.

  stop
    Kill dnsmasq + HTTP server, clean up temp files.

Examples:
  network-boot.sh start eth0 8080 build/magic-stick_0.1.14.iso
  network-boot.sh stop
USAGE
    exit 1
}

cleanup() {
    echo "[network-boot] Cleaning up..."
    if [[ -f "$WORK_DIR/dnsmasq.pid" ]]; then
        kill "$(cat "$WORK_DIR/dnsmasq.pid")" 2>/dev/null || true
        rm -f "$WORK_DIR/dnsmasq.pid"
    fi
    if [[ -f "$WORK_DIR/http.pid" ]]; then
        kill "$(cat "$WORK_DIR/http.pid")" 2>/dev/null || true
        rm -f "$WORK_DIR/http.pid"
    fi
    if mountpoint -q "$WORK_DIR/iso" 2>/dev/null; then
        umount "$WORK_DIR/iso" 2>/dev/null || true
    fi
    echo "[network-boot] Cleanup done."
}

start_server() {
    local iface="$1"
    local http_port="$2"
    local iso_path="$3"

    if [[ ! -f "$iso_path" ]]; then
        echo "[network-boot] ERROR: ISO not found: $iso_path" >&2
        exit 1
    fi

    local host_ip
    host_ip=$(ip -4 addr show "$iface" | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
    if [[ -z "$host_ip" ]]; then
        echo "[network-boot] ERROR: No IPv4 on interface $iface" >&2
        exit 1
    fi
    local subnet="${host_ip%.*}.0/24"

    echo "[network-boot] Interface: $iface  IP: $host_ip  HTTP port: $http_port"
    echo "[network-boot] ISO: $iso_path"

    mkdir -p "$WORK_DIR/iso" "$WORK_DIR/tftp" "$WORK_DIR/www"

    # Mount ISO read-only
    echo "[network-boot] Mounting ISO..."
    mount -o loop,ro "$iso_path" "$WORK_DIR/iso"

    # Extract kernel + initrd from ISO's casper/ directory
    echo "[network-boot] Extracting kernel/initrd..."
    cp "$WORK_DIR/iso/casper/vmlinuz" "$WORK_DIR/www/vmlinuz"
    cp "$WORK_DIR/iso/casper/initrd" "$WORK_DIR/www/initrd"
    chmod 644 "$WORK_DIR/www/vmlinuz" "$WORK_DIR/www/initrd"

    # iPXE binary
    local ipxe_src=""
    if [[ -f "$PROJECT_DIR/build/undionly.kpxe" ]]; then
        ipxe_src="$PROJECT_DIR/build/undionly.kpxe"
    elif command -v ipxe-bootimgs &>/dev/null; then
        ipxe_src="$(dpkg -L ipxe-bootimgs 2>/dev/null | grep 'undionly\.kpxe$' | head -1)" || true
    fi
    if [[ -n "$ipxe_src" && -f "$ipxe_src" ]]; then
        cp "$ipxe_src" "$WORK_DIR/tftp/undionly.kpxe"
        echo "[network-boot] iPXE: $ipxe_src"
    else
        echo "[network-boot] WARNING: no iPXE binary found." >&2
        echo "  Install ipxe-bootimgs or place undionly.kpxe in build/" >&2
        echo "  Without iPXE, PXE clients will not be able to chain-load." >&2
        echo "  You can still boot clients that already have iPXE." >&2
    fi

    # iPXE script served alongside the kernel
    cat > "$WORK_DIR/www/magic-stick.ipxe" <<IPXE_EOF
#!ipxe
echo Magic Stick Network Boot
echo Booting from ${host_ip}:${http_port}...
kernel http://${host_ip}:${http_port}/vmlinuz boot=casper netboot=nfs ip=dhcp
initrd http://${host_ip}:${http_port}/initrd
boot
IPXE_EOF
    echo "[network-boot] iPXE script: $WORK_DIR/www/magic-stick.ipxe"

    # dnsmasq config — proxy DHCP + TFTP only
    cat > "$WORK_DIR/dnsmasq.conf" <<DNSMASQ_EOF
port=0
log-dhcp
interface=$iface
bind-interfaces
except-interface=lo
dhcp-range=proxy,$subnet,proxy
dhcp-no-override
dhcp-option=tag:pxeclient,option:bootfile-name,undionly.kpxe
dhcp-boot=undionly.kpxe
enable-tftp
tftp-root=$WORK_DIR/tftp
DNSMASQ_EOF

    # Start dnsmasq (daemon)
    dnsmasq -C "$WORK_DIR/dnsmasq.conf" --pid-file="$WORK_DIR/dnsmasq.pid"
    local dns_pid
    dns_pid=$(cat "$WORK_DIR/dnsmasq.pid")
    echo "[network-boot] dnsmasq started (PID $dns_pid)"

    # Start Python HTTP server (background)
    cd "$WORK_DIR/www"
    python3 -m http.server "$http_port" --bind "$host_ip" &
    local http_pid=$!
    echo "$http_pid" > "$WORK_DIR/http.pid"
    echo "[network-boot] HTTP server started (PID $http_pid) — http://${host_ip}:${http_port}/"

    echo
    echo "[network-boot] === Server running ==="
    echo "  PXE clients:  DHCP proxy + TFTP (undionly.kpxe)"
    echo "  Kernel/initrd: http://${host_ip}:${http_port}/"
    echo "  iPXE script:   http://${host_ip}:${http_port}/magic-stick.ipxe"
    echo "  Press Ctrl+C to stop both servers."

    wait "$http_pid"
}

# --- Main ---
if [[ $# -lt 1 ]]; then
    usage
fi

case "${1}" in
    start)
        if [[ $# -lt 4 ]]; then
            echo "[network-boot] Usage: start <iface> <http_port> <iso_path>" >&2
            exit 1
        fi
        trap cleanup EXIT
        start_server "$2" "$3" "$4"
        ;;
    stop)
        cleanup
        rm -rf "$WORK_DIR"
        echo "[network-boot] Stopped."
        ;;
    *)
        usage
        ;;
esac
