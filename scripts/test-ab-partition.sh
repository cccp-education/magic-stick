#!/usr/bin/env bash
set -euo pipefail

# Magic Stick A/B Partition Test Suite (v0.3.0 layout: p1=bios_grub, p2=ESP, p3=system_a, p4=system_b, p5=persistence)
# Simule une cle USB A/B avec une image disque (loop device)
# Utilisable SANS sudo pour les tests non-root, ou AVEC sudo pour les tests full-stack

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build"
TEST_DISK="${BUILD_DIR}/test-usb.img"
DISK_SIZE_GB=4
DISK_SIZE=$((DISK_SIZE_GB * 1024 * 1024 * 1024))

BIOSGRUB_LABEL="bios_grub"
ESP_LABEL="ESP"
SYSTEM_A_LABEL="system_a"
SYSTEM_B_LABEL="system_b"
PERSISTENCE_LABEL="persistence"

ISO_FILE="${1:-}"
die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
pass() { echo "  [OK] $*"; }
fail() { echo "  [FAIL] $*" >&2; return 1; }
warn() { echo "  [WARN] $*" >&2; }

cleanup_loop() {
    local loopdev="${1:-}"
    [[ -z "$loopdev" ]] && return 0
    info "Cleaning up loop device ${loopdev}..."
    for i in 1 2 3 4 5; do
        umount "${loopdev}p${i}" 2>/dev/null || true
    done
    losetup -d "$loopdev" 2>/dev/null || true
}

cmd_test_partition() {
    echo "=== TEST: Partition A/B layout (v0.3.0: 5 partitions) ==="
    echo ""

    if [[ "$(id -u)" -ne 0 ]]; then
        info "Running in non-root mode (partition tests limited)"
        [[ -f "$TEST_DISK" ]] && pass "Test disk image exists: ${TEST_DISK}" || die "No test disk. Run 'create-disk' with sudo first."
        return 0
    fi

    info "Root mode: full partition test"

    LOOP_DEV=$(losetup -f --show "$TEST_DISK" 2>/dev/null || true)
    if [[ -z "$LOOP_DEV" ]]; then
        LOOP_DEV=$(losetup -f 2>/dev/null || true)
        [[ -n "$LOOP_DEV" ]] || die "No free loop device available"
        losetup "$LOOP_DEV" "$TEST_DISK" 2>/dev/null || die "Cannot setup loop device for ${TEST_DISK}"
    fi
    info "Loop device: ${LOOP_DEV}"

    trap 'cleanup_loop "${LOOP_DEV}"' EXIT

    echo ""
    echo "Partition table:"
    parted -s "$LOOP_DEV" print 2>/dev/null | head -20 || fail "Cannot read partition table"

    echo ""
    echo "Partition details:"
    for i in 1 2 3 4 5; do
        local part="${LOOP_DEV}p${i}"
        if [[ -b "$part" ]]; then
            local label fstype size
            label=$(blkid -s LABEL -o value "$part" 2>/dev/null || echo "N/A")
            fstype=$(blkid -s TYPE -o value "$part" 2>/dev/null || echo "N/A")
            size=$(lsblk -n -o SIZE "$part" 2>/dev/null || echo "N/A")
            echo "  ${part}: label=${label} fstype=${fstype} size=${size}"
        else
            echo "  ${part}: NOT FOUND"
        fi
    done

    echo ""
    echo "Checking UEFI ESP..."
    for part in "${LOOP_DEV}p2" "${LOOP_DEV}2"; do
        if [[ -b "$part" ]]; then
            local esp_mount
            esp_mount=$(mktemp -d)
            if mount -o ro "$part" "$esp_mount" 2>/dev/null; then
                if [[ -f "${esp_mount}/EFI/BOOT/BOOTX64.EFI" ]]; then
                    pass "BOOTX64.EFI found on ESP"
                else
                    warn "BOOTX64.EFI not found on ESP"
                    ls -R "${esp_mount}/EFI" 2>/dev/null || warn "No EFI directory on ESP"
                fi
                umount "$esp_mount" 2>/dev/null || true
            else
                warn "Cannot mount ESP"
            fi
            rmdir "$esp_mount" 2>/dev/null || true
            break
        fi
    done

    echo ""
    echo "Checking persistence.conf..."
    for part in "${LOOP_DEV}p5" "${LOOP_DEV}5"; do
        if [[ -b "$part" ]]; then
            local mount_point
            mount_point=$(mktemp -d)
            if mount "$part" "$mount_point" 2>/dev/null; then
                if [[ -f "${mount_point}/persistence.conf" ]]; then
                    pass "persistence.conf found"
                    cat "${mount_point}/persistence.conf"
                else
                    warn "persistence.conf not found"
                fi
                umount "$mount_point" 2>/dev/null || true
            else
                warn "Cannot mount persistence partition"
            fi
            rmdir "$mount_point" 2>/dev/null || true
            break
        fi
    done

    echo ""
    echo "Checking GRUB installation on system_a..."
    for part in "${LOOP_DEV}p3" "${LOOP_DEV}3"; do
        if [[ -b "$part" ]]; then
            local mount_point
            mount_point=$(mktemp -d)
            if mount "$part" "$mount_point" 2>/dev/null; then
                if [[ -f "${mount_point}/boot/grub/grub.cfg" ]]; then
                    pass "grub.cfg found"
                    head -20 "${mount_point}/boot/grub/grub.cfg"
                else
                    warn "grub.cfg not found"
                fi

                if [[ -f "${mount_point}/boot/grub/i386-pc/boot.img" ]]; then
                    pass "GRUB BIOS boot.img present"
                else
                    warn "GRUB BIOS boot.img not found"
                fi

                if [[ -f "${mount_point}/boot/grub/i386-pc/core.img" ]]; then
                    pass "GRUB BIOS core.img present"
                    local core_size
                    core_size=$(stat -c%s "${mount_point}/boot/grub/i386-pc/core.img" 2>/dev/null || echo 0)
                    if [[ "$core_size" -gt 100000 ]]; then
                        pass "core.img is ${core_size} bytes (modules embedded: ext2, gfxterm, etc.)"
                    else
                        fail "core.img is only ${core_size} bytes — modules NOT embedded, GRUB will drop to prompt"
                    fi
                else
                    warn "GRUB BIOS core.img not found"
                fi

                umount "$mount_point" 2>/dev/null || true
            else
                warn "Cannot mount system_a partition"
            fi
            rmdir "$mount_point" 2>/dev/null || true
            break
        fi
    done

    echo ""
    echo "=== Partition test complete ==="
}

cmd_create_disk() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "This command must be run as root (use sudo)"
    fi

    mkdir -p "$BUILD_DIR"

    if [[ -f "$TEST_DISK" ]]; then
        info "Removing existing test disk..."
        rm -f "$TEST_DISK"
    fi

    info "Creating ${DISK_SIZE_GB}GB test disk image..."
    dd if=/dev/zero of="$TEST_DISK" bs=1M count=$((DISK_SIZE_GB * 1024)) status=progress conv=sparse

    info "Creating GPT partition table (v0.3.0 layout)..."
    parted -s "$TEST_DISK" mklabel gpt

    info "Creating partition 1: ${BIOSGRUB_LABEL} (1 MiB)..."
    parted -s "$TEST_DISK" mkpart "${BIOSGRUB_LABEL}" 1MiB 2MiB
    parted -s "$TEST_DISK" set 1 bios_grub on

    info "Creating partition 2: ${ESP_LABEL} (100 MiB, FAT32)..."
    parted -s "$TEST_DISK" mkpart "${ESP_LABEL}" fat32 2MiB 102MiB
    parted -s "$TEST_DISK" set 2 esp on

    info "Creating partition 3: ${SYSTEM_A_LABEL} (1 GiB)..."
    parted -s "$TEST_DISK" mkpart "${SYSTEM_A_LABEL}" ext4 102MiB 1126MiB

    info "Creating partition 4: ${SYSTEM_B_LABEL} (1 GiB)..."
    parted -s "$TEST_DISK" mkpart "${SYSTEM_B_LABEL}" ext4 1126MiB 2150MiB

    info "Creating partition 5: ${PERSISTENCE_LABEL} (rest)..."
    parted -s "$TEST_DISK" mkpart "${PERSISTENCE_LABEL}" ext4 2150MiB 100%

    info "Formatting partitions..."
    local LOOP_DEV
    LOOP_DEV=$(losetup -f --show "$TEST_DISK")
    trap 'cleanup_loop "${LOOP_DEV}"' EXIT

    partprobe "$LOOP_DEV" 2>/dev/null || true
    sleep 1

    mkfs.fat -F32 -n "${ESP_LABEL}" "${LOOP_DEV}p2"
    mkfs.ext4 -L "${SYSTEM_A_LABEL}" "${LOOP_DEV}p3"
    mkfs.ext4 -L "${SYSTEM_B_LABEL}" "${LOOP_DEV}p4"
    mkfs.ext4 -L "${PERSISTENCE_LABEL}" "${LOOP_DEV}p5"

    info "Creating persistence.conf..."
    local mount_point
    mount_point=$(mktemp -d)
    mount "${LOOP_DEV}p5" "$mount_point"
    cat > "${mount_point}/persistence.conf" << 'EOF'
/ union
EOF
    umount "$mount_point"
    rmdir "$mount_point"

    cleanup_loop "$LOOP_DEV"
    trap - EXIT

    echo ""
    echo "=== Test disk created ==="
    echo "Image: ${TEST_DISK}"
    echo "Size:  ${DISK_SIZE_GB}GB"
}

cmd_run_setup_ab() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "This command must be run as root (use sudo)"
    fi

    local LOOP_DEV
    LOOP_DEV=$(losetup -f --show "$TEST_DISK" 2>/dev/null || true)
    [[ -n "$LOOP_DEV" ]] || die "Cannot setup loop device for ${TEST_DISK}"
    trap 'cleanup_loop "${LOOP_DEV}"' EXIT

    info "Running update-system.sh setup-ab on ${LOOP_DEV}..."
    "${SCRIPT_DIR}/update-system.sh" setup-ab "$LOOP_DEV" "${ISO_FILE:-}"

    cleanup_loop "$LOOP_DEV"
    trap - EXIT
}

cmd_install_iso() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "This command must be run as root (use sudo)"
    fi
    [[ -n "${ISO_FILE:-}" && -f "$ISO_FILE" ]] || die "ISO file required: ${0} install <iso> [A|B]"
    local target="${2:-A}"

    local LOOP_DEV
    LOOP_DEV=$(losetup -f --show "$TEST_DISK" 2>/dev/null || true)
    [[ -n "$LOOP_DEV" ]] || die "Cannot setup loop device for ${TEST_DISK}"
    trap 'cleanup_loop "${LOOP_DEV}"' EXIT

    info "Running update-system.sh install ${target} on ${LOOP_DEV}..."
    "${SCRIPT_DIR}/update-system.sh" install "$LOOP_DEV" "$ISO_FILE" "$target"

    cleanup_loop "$LOOP_DEV"
    trap - EXIT
}

cmd_status() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "This command must be run as root (use sudo)"
    fi

    local LOOP_DEV
    LOOP_DEV=$(losetup -f --show "$TEST_DISK" 2>/dev/null || true)
    [[ -n "$LOOP_DEV" ]] || die "Cannot setup loop device for ${TEST_DISK}"
    trap 'cleanup_loop "${LOOP_DEV}"' EXIT

    "${SCRIPT_DIR}/update-system.sh" status "$LOOP_DEV"

    cleanup_loop "$LOOP_DEV"
    trap - EXIT
}

usage() {
    cat << USAGE
Magic Stick A/B Partition Test Suite (v0.3.0 layout)

Usage: ${0##*/} <command> [options]

Commands:
  create-disk               Create a ${DISK_SIZE_GB}GB loopback disk image for testing
  test                      Test partition layout (needs create-disk first)
  setup-ab [iso]            Run update-system.sh setup-ab on the loopback disk
  install <iso> [A|B]       Run update-system.sh install on the loopback disk
  status                    Run update-system.sh status on the loopback disk
  full-test <iso>          create-disk + setup-ab + install A + test + status

Options:
  <iso>                    Path to Magic Stick ISO file

Examples:
  sudo ${0##*/} create-disk
  sudo ${0##*/} setup-ab build/magic-stick_0.1.0.iso
  sudo ${0##*/} install build/magic-stick_0.1.0.iso A
  sudo ${0##*/} test
  sudo ${0##*/} status
USAGE
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
    create-disk)
        cmd_create_disk
        ;;
    test)
        cmd_test_partition
        ;;
    setup-ab)
        ISO_FILE="${1:-}"
        cmd_run_setup_ab
        ;;
    install)
        ISO_FILE="${1:-}"
        cmd_install_iso "$@"
        ;;
    status)
        cmd_status
        ;;
    full-test)
        ISO_FILE="${1:-}"
        [[ -f "$ISO_FILE" ]] || die "ISO file not found: ${ISO_FILE}"
        cmd_create_disk
        cmd_run_setup_ab
        cmd_install_iso "$ISO_FILE" "A"
        cmd_test_partition
        cmd_status
        ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown command: ${COMMAND}" >&2
        usage
        exit 1
        ;;
esac
