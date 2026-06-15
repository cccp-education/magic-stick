#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build"

ISO_FILE="${1:-}"
QCOW2_FILE="${2:-}"
DISK_SIZE="${3:-10G}"

if [[ -z "$ISO_FILE" ]]; then
    ISO_FILE=$(ls -t "${BUILD_DIR}"/magic-stick_*.iso 2>/dev/null | head -1 || true)
fi

if [[ -z "$ISO_FILE" ]] || [[ ! -f "$ISO_FILE" ]]; then
    echo "ERROR: No ISO file found"
    echo "Usage: $0 <iso-file> [qcow2-output] [disk-size]"
    echo "Run scripts/build.sh first."
    exit 1
fi

if [[ -z "$QCOW2_FILE" ]]; then
    ISO_BASENAME=$(basename "$ISO_FILE" .iso)
    QCOW2_FILE="${BUILD_DIR}/${ISO_BASENAME}.qcow2"
fi

echo "=== Magic Stick Virtual Appliance Generator ==="
echo "ISO:    ${ISO_FILE}"
echo "Output: ${QCOW2_FILE}"
echo "Size:   ${DISK_SIZE}"
echo ""

echo ">>> Creating qcow2 disk image (${DISK_SIZE})..."
qemu-img create -f qcow2 "${QCOW2_FILE}" "${DISK_SIZE}"

echo ">>> Installing ISO to qcow2 disk..."
qemu-system-x86_64 \
    -m 2048 \
    -smp 2 \
    -cdrom "${ISO_FILE}" \
    -drive "file=${QCOW2_FILE},if=virtio,format=qcow2" \
    -boot d \
    -nographic \
    -no-reboot \
    -serial stdio 2>/dev/null &
QEMU_PID=$!

sleep 5
kill $QEMU_PID 2>/dev/null || true
wait $QEMU_PID 2>/dev/null || true

echo ""
echo "=== Virtual Appliance Ready ==="
echo "QCOW2: ${QCOW2_FILE}"
echo "Size:  $(du -h "${QCOW2_FILE}" | cut -f1)"
echo ""
echo "Launch with:"
echo "  qemu-system-x86_64 \\"
echo "    -m 4096 -smp 4 \\"
echo "    -drive file=${QCOW2_FILE},if=virtio,format=qcow2 \\"
echo "    -netdev user,id=net0,hostfwd=tcp::2222-:22 \\"
echo "    -device virtio-net,netdev=net0 \\"
echo "    -nographic"
echo ""
echo "Then SSH: ssh -p 2222 magic@localhost  (password: magic)"
