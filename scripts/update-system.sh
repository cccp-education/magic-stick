#!/usr/bin/env bash
set -euo pipefail

VERSION="0.3.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build"

BIOSGRUB_LABEL="bios_grub"
ESP_LABEL="ESP"
SYSTEM_A_LABEL="system_a"
SYSTEM_B_LABEL="system_b"
PERSISTENCE_LABEL="persistence"

FORCE_YES=false
DRY_RUN=false

dry_run_info() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would execute: $*"
    fi
}

dry_run_exec() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would execute: $*"
    else
        "$@"
    fi
}

usage() {
    cat << USAGE
Magic Stick A/B System Manager v${VERSION}

Usage: update-system.sh [options] <command> [args]

Options:
  -y, --yes                  Skip all confirmation prompts (DANGEROUS!)
  -n, --dry-run              Show what would be done without executing

Commands:
  setup-ab <device> [iso]    Partition device + install GRUB + flash initial ISO
  install <device> <iso>     Install ISO content to a partition (A or B)
  switch <device>            Switch default boot partition (A<->B)
  status <device>            Show current A/B partition status
  verify <device>            Verify partition layout and GRUB installation

GPT partition layout (v${VERSION}):
  /dev/sdX1  bios_grub     (1 MB)  - Legacy BIOS GRUB stage1.5
  /dev/sdX2  ESP           (512 MB) - UEFI System Partition (FAT32)
  /dev/sdX3  system_a      (8 GB)   - System partition A
  /dev/sdX4  system_b      (8 GB)   - System partition B
  /dev/sdX5  persistence  (rest)    - User data (never touched by updates)

Each system partition contains:
  /casper/vmlinuz         - Linux kernel
  /casper/initrd.img      - Initial ramdisk
  /casper/filesystem.squashfs - Compressed root filesystem

GRUB is installed for BOTH Legacy BIOS (i386-pc on MBR + bios_grub)
and UEFI (x86_64-efi on ESP). Switching is done by changing the
default entry in grub.cfg on system_a.

WARNING: These commands modify partition tables and write to raw devices!
USE WITH CAUTION - always verify the target device.
USAGE
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARNING: $*" >&2
}

info() {
    echo "==> $*"
}

prompt_confirm() {
    if [[ "$FORCE_YES" == "true" ]]; then
        return 0
    fi
    local prompt="${1:-Type 'YES' to continue: }"
    read -rp "$prompt" confirm
    [[ "$confirm" == "YES" ]]
}

get_part_prefix() {
    local device="$1"
    if [[ "$device" =~ ^/dev/(nvme|loop) ]]; then
        echo "${device}p"
    else
        echo "${device}"
    fi
}

get_device_size_bytes() {
    local device="$1"
    blockdev --getsize64 "$device" 2>/dev/null || echo 0
}

label_to_partnum() {
    case "$1" in
        "${BIOSGRUB_LABEL}") echo 1 ;;
        "${ESP_LABEL}") echo 2 ;;
        "${SYSTEM_A_LABEL}") echo 3 ;;
        "${SYSTEM_B_LABEL}") echo 4 ;;
        "${PERSISTENCE_LABEL}") echo 5 ;;
        *) echo 0 ;;
    esac
}

find_partition_by_label() {
    local device="$1"
    local label="$2"
    local prefix
    prefix=$(get_part_prefix "$device")
    local partnum
    partnum=$(label_to_partnum "$label")
    if [[ "$partnum" -eq 0 ]]; then
        blkid -L "$label" -o device 2>/dev/null || echo ""
    else
        echo "${prefix}${partnum}"
    fi
}

is_partition_mounted() {
    local part="$1"
    mount | grep -q "$part" 2>/dev/null
}

detect_active_partition() {
    local device="$1"
    local prefix
    prefix=$(get_part_prefix "$device")

    local part_a="${prefix}3"
    local part_b="${prefix}4"

    if mount | grep -q "$part_a"; then
        echo "A"
    elif mount | grep -q "$part_b"; then
        echo "B"
    else
        echo "A"
    fi
}

read_grub_default() {
    local device="$1"
    local prefix
    prefix=$(get_part_prefix "$device")
    local part_a="${prefix}3"

    local mount_point
    mount_point=$(mktemp -d)

    if ! mount "${part_a}" "$mount_point" 2>/dev/null; then
        rmdir "$mount_point" 2>/dev/null || true
        echo "A"
        return
    fi
    trap 'umount "${part_a}" 2>/dev/null || true; rmdir "$mount_point" 2>/dev/null || true' RETURN EXIT

    local default_entry
    default_entry=$(grep -E '^set default=' "${mount_point}/boot/grub/grub.cfg" 2>/dev/null | head -1 | sed 's/set default=//' | tr -d '"' || echo "0")

    if [[ "$default_entry" == "0" ]]; then
        echo "A"
    else
        echo "B"
    fi
}

cmd_status() {
    local device="$1"

    [[ -b "$device" ]] || die "${device} is not a block device"

    local prefix
    prefix=$(get_part_prefix "$device")

    echo "=== Magic Stick A/B Status ==="
    echo "Device: ${device}"
    echo ""

    echo "Partition table:"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "${device}" 2>/dev/null || \
        fdisk -l "${device}" 2>/dev/null || \
        echo "  (Cannot read partition table)"
    echo ""

    echo "Partition details:"
    for i in 1 2 3 4 5; do
        local part="${prefix}${i}"
        if [[ -b "$part" ]]; then
            local label
            label=$(blkid -s LABEL -o value "$part" 2>/dev/null || echo "N/A")
            local fstype
            fstype=$(blkid -s TYPE -o value "$part" 2>/dev/null || echo "N/A")
            local size
            size=$(lsblk -n -o SIZE "$part" 2>/dev/null || echo "N/A")
            echo "  ${part}: label=${label} fstype=${fstype} size=${size}"
        else
            echo "  ${part}: NOT FOUND"
        fi
    done

    echo ""
    echo "Boot configuration:"
    local active
    active=$(detect_active_partition "$device")
    echo "  Active partition: ${active}"

    echo ""
    echo "System partition contents:"
    for part_label in "$SYSTEM_A_LABEL" "$SYSTEM_B_LABEL"; do
        local part
        part=$(find_partition_by_label "$device" "$part_label")
        if [[ -b "$part" ]]; then
            echo ""
            echo "  ${part_label} (${part}):"
            local mount_point
            mount_point=$(mktemp -d)
            if mount -o ro "$part" "$mount_point" 2>/dev/null; then
                trap 'umount "$part" 2>/dev/null || true; rmdir "$mount_point" 2>/dev/null || true' RETURN EXIT
                for f in casper/vmlinuz casper/initrd.img casper/filesystem.squashfs; do
                    if [[ -f "${mount_point}/${f}" ]]; then
                        local fsize
                        fsize=$(du -h "${mount_point}/${f}" 2>/dev/null | cut -f1 || echo "?")
                        echo "    ${f}: ${fsize}"
                    else
                        echo "    ${f}: MISSING"
                    fi
                done
                if [[ -f "${mount_point}/boot/grub/grub.cfg" ]]; then
                    local def
                    def=$(grep 'set default=' "${mount_point}/boot/grub/grub.cfg" | head -1 | tr -d '"')
                    echo "    GRUB: ${def}"
                fi
            else
                echo "    (cannot mount)"
                rmdir "$mount_point" 2>/dev/null || true
            fi
        fi
    done
}

cmd_setup_ab() {
    local device="$1"
    local iso_file="${2:-}"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would setup A/B partitions on ${device}"
        echo "[DRY-RUN]   - Create GPT partition table"
        echo "[DRY-RUN]   - Partition 1: ${BIOSGRUB_LABEL} (1 MB, bios_grub flag)"
        echo "[DRY-RUN]   - Partition 2: ${ESP_LABEL} (512 MB, FAT32, esp flag)"
        echo "[DRY-RUN]   - Partition 3: ${SYSTEM_A_LABEL} (8 GB, ext4)"
        echo "[DRY-RUN]   - Partition 4: ${SYSTEM_B_LABEL} (8 GB, ext4)"
        echo "[DRY-RUN]   - Partition 5: ${PERSISTENCE_LABEL} (rest, ext4)"
        echo "[DRY-RUN]   - Install GRUB Legacy (i386-pc) + UEFI (x86_64-efi)"
        [[ -n "$iso_file" ]] && echo "[DRY-RUN]   - Install ISO ${iso_file} to System A"
        return 0
    fi

    [[ "$(id -u)" -eq 0 ]] || die "This command must be run as root (use sudo)"
    [[ -b "$device" ]] || die "${device} is not a block device"

    local device_size
    device_size=$(get_device_size_bytes "$device")
    local min_size=$((25 * 1024 * 1024 * 1024))

    [[ "$device_size" -ge "$min_size" ]] || die "Device ${device} is too small ($(numfmt --to=iec "$device_size")). Minimum required: 25 GB (ESP 512MB + 2x8GB system + persistence)"

    echo "=== Magic Stick A/B Setup v${VERSION} ==="
    echo "Device: ${device} ($(numfmt --to=iec "$device_size"))"
    echo ""
    echo "New GPT partition layout (Legacy BIOS + UEFI dual boot):"
    echo "  Partition 1: ${BIOSGRUB_LABEL}    (1 MB)    - Legacy GRUB stage1.5"
    echo "  Partition 2: ${ESP_LABEL}         (512 MB)  - UEFI System Partition"
    echo "  Partition 3: ${SYSTEM_A_LABEL}    (8 GB)    - System A"
    echo "  Partition 4: ${SYSTEM_B_LABEL}    (8 GB)    - System B"
    echo "  Partition 5: ${PERSISTENCE_LABEL} (rest)    - User data"
    echo ""
    echo "WARNING: This will ERASE ALL DATA on ${device}!"
    echo ""
    prompt_confirm || { echo "Aborted."; exit 0; }

    local prefix
    prefix=$(get_part_prefix "$device")

    echo ""
    info "Unmounting all partitions on ${device}..."
    for i in 1 2 3 4 5; do
        umount "${prefix}${i}" 2>/dev/null || true
    done
    umount "${device}"* 2>/dev/null || true

    # ── GPT partition layout ───────────────────────────────
    # 1: bios_grub   (1 MiB,  no FS, flag bios_grub)
    # 2: ESP         (512 MiB, FAT32, flag esp)
    # 3: system_a    (8 GiB,  ext4)
    # 4: system_b    (8 GiB,  ext4)
    # 5: persistence (rest,   ext4)
    #
    # parted uses MiB=1048576 bytes, GiB=1073741824 bytes.
    # Sizes: 1 MiB = end of p1, +512 MiB = end of p2 (513 MiB),
    #        +8 GiB = end of p3 (~8513 MiB),
    #        +8 GiB = end of p4 (~16513 MiB),
    #        rest up to 100%.

    info "Creating GPT partition table..."
    parted -s "$device" mklabel gpt

    info "Creating partition 1: ${BIOSGRUB_LABEL} (1 MiB)..."
    parted -s "$device" mkpart "${BIOSGRUB_LABEL}" 1MiB 2MiB
    parted -s "$device" set 1 bios_grub on

    info "Creating partition 2: ${ESP_LABEL} (512 MiB, FAT32)..."
    parted -s "$device" mkpart "${ESP_LABEL}" fat32 2MiB 514MiB
    parted -s "$device" set 2 esp on

    info "Creating partition 3: ${SYSTEM_A_LABEL} (8 GiB)..."
    parted -s "$device" mkpart "${SYSTEM_A_LABEL}" ext4 514MiB 8706MiB

    info "Creating partition 4: ${SYSTEM_B_LABEL} (8 GiB)..."
    parted -s "$device" mkpart "${SYSTEM_B_LABEL}" ext4 8706MiB 16898MiB

    info "Creating partition 5: ${PERSISTENCE_LABEL} (rest)..."
    parted -s "$device" mkpart "${PERSISTENCE_LABEL}" ext4 16898MiB 100%

    info "Informing kernel of partition changes..."
    partprobe "$device" 2>/dev/null || true
    sleep 2

    info "Formatting partitions..."
    mkfs.fat -F32 -n "${ESP_LABEL}" "${prefix}2"
    mkfs.ext4 -L "${SYSTEM_A_LABEL}" "${prefix}3"
    mkfs.ext4 -L "${SYSTEM_B_LABEL}" "${prefix}4"
    mkfs.ext4 -L "${PERSISTENCE_LABEL}" "${prefix}5"

    info "Creating persistence configuration..."
    local part_p="${prefix}5"
    local mount_point
    mount_point=$(mktemp -d)
    mount "${part_p}" "$mount_point"
    trap 'umount "${part_p}" 2>/dev/null || true; rmdir "$mount_point" 2>/dev/null || true' RETURN EXIT
    cat > "${mount_point}/persistence.conf" << 'EOF'
/ union
EOF

    info "Installing GRUB (Legacy BIOS + UEFI) to ${device}..."
    install_grub "$device"

    echo ""
    echo "=== A/B Setup complete! ==="
    echo ""
    echo "Partition layout:"
    lsblk -o NAME,SIZE,FSTYPE,LABEL "${device}"
    echo ""

    if [[ -n "$iso_file" ]]; then
        info "Installing ISO to System A..."
        cmd_install "$device" "$iso_file" "A"
    else
        echo "Next steps:"
        echo "  1. Install initial system:"
        echo "     sudo $0 install ${device} /path/to/magic-stick.iso A"
        echo ""
        echo "  2. Optional: install to System B:"
        echo "     sudo $0 install ${device} /path/to/magic-stick.iso B"
        echo ""
        echo "  3. Boot from USB — works in BOTH Legacy BIOS and UEFI mode"
    fi
}

install_grub() {
    local device="$1"

    local prefix
    prefix=$(get_part_prefix "$device")
    local part_esp="${prefix}2"
    local part_a="${prefix}3"

    local mount_esp=""
    local mount_a=""

    cleanup_grub_install() {
        if [[ -n "$mount_a" ]]; then
            sync
            umount "$mount_a" 2>/dev/null || true
            rmdir "$mount_a" 2>/dev/null || true
        fi
        if [[ -n "$mount_esp" ]]; then
            sync
            umount "$mount_esp" 2>/dev/null || true
            rmdir "$mount_esp" 2>/dev/null || true
        fi
    }

    mount_a=$(mktemp -d)
    mount "${part_a}" "$mount_a" || die "Cannot mount ${part_a} for GRUB installation"
    mount_esp=$(mktemp -d)
    mount "${part_esp}" "$mount_esp" || die "Cannot mount ${part_esp} (ESP) for GRUB installation"
    trap cleanup_grub_install RETURN EXIT

    mkdir -p "${mount_a}/boot/grub"
    mkdir -p "${mount_esp}/EFI/BOOT"

    generate_grub_cfg "${mount_a}/boot/grub/grub.cfg" "A"

    info "Installing GRUB Legacy (i386-pc) to ${device} MBR + bios_grub..."
    grub-install --target=i386-pc \
        --boot-directory="${mount_a}/boot" \
        --modules="biosdisk ext2 part_gpt search search_label search_fs_uuid normal configfile echo linux all_video gfxterm gfxmenu font video video_fb png jpeg tga gettext" \
        --force \
        "$device" || warn "GRUB Legacy installation failed (non-fatal if UEFI works)"

    info "Installing GRUB UEFI (x86_64-efi) to ESP..."
    grub-install --target=x86_64-efi \
        --efi-directory="${mount_esp}" \
        --boot-directory="${mount_a}/boot" \
        --modules="ext2 part_gpt part_msdos fat search search_label search_fs_uuid normal configfile echo linux all_video gfxterm gfxmenu font video video_fb png jpeg tga gettext chain efi_gop efi_uga boot" \
        --removable \
        --no-nvram \
        "$device" || warn "GRUB UEFI installation failed"

    info "GRUB installed: Legacy BIOS (i386-pc) + UEFI (x86_64-efi)"
    sync
}

generate_grub_cfg() {
    local cfg_file="$1"
    local default="$2"

    local default_entry
    if [[ "$default" == "B" ]]; then
        default_entry="1"
    else
        default_entry="0"
    fi

    cat > "$cfg_file" << GRUBCFG
# Magic Stick A/B Boot Configuration
# Generated by update-system.sh v${VERSION}
set default=${default_entry}
set timeout=10
set gfxmode=auto
set gfxpayload=keep

insmod all_video
insmod gfxterm
terminal_output gfxterm

menuentry "Magic Stick - System A" {
    search --set=root --label ${SYSTEM_A_LABEL}
    linux /casper/vmlinuz boot=casper persistence persistence-label=${PERSISTENCE_LABEL} username=magic hostname=magic-stick locales=fr_FR.UTF-8 keyboard-layouts=fr quiet splash ---
    initrd /casper/initrd.img
}

menuentry "Magic Stick - System B" {
    search --set=root --label ${SYSTEM_B_LABEL}
    linux /casper/vmlinuz boot=casper persistence persistence-label=${PERSISTENCE_LABEL} username=magic hostname=magic-stick locales=fr_FR.UTF-8 keyboard-layouts=fr quiet splash ---
    initrd /casper/initrd.img
}

menuentry "Magic Stick - System A (nomodeset)" {
    search --set=root --label ${SYSTEM_A_LABEL}
    linux /casper/vmlinuz boot=casper persistence persistence-label=${PERSISTENCE_LABEL} username=magic hostname=magic-stick locales=fr_FR.UTF-8 keyboard-layouts=fr nomodeset ---
    initrd /casper/initrd.img
}

menuentry "Magic Stick - System B (nomodeset)" {
    search --set=root --label ${SYSTEM_B_LABEL}
    linux /casper/vmlinuz boot=casper persistence persistence-label=${PERSISTENCE_LABEL} username=magic hostname=magic-stick locales=fr_FR.UTF-8 keyboard-layouts=fr nomodeset ---
    initrd /casper/initrd.img
}
GRUBCFG
}

extract_iso_to_partition() {
    local iso_file="$1"
    local target_part="$2"
    local target_label="$3"

    info "Extracting ISO content to ${target_part} (${target_label})..."

    local iso_mount=""
    local mount_point=""
    local exit_code=0

    cleanup() {
        if [[ -n "$iso_mount" ]]; then
            umount "$iso_mount" 2>/dev/null || true
            rmdir "$iso_mount" 2>/dev/null || true
        fi
        if [[ -n "$mount_point" ]]; then
            sync
            umount "$mount_point" 2>/dev/null || true
            rmdir "$mount_point" 2>/dev/null || true
        fi
    }

    mount_point=$(mktemp -d)
    if ! mount "${target_part}" "$mount_point"; then
        rmdir "$mount_point" 2>/dev/null || true
        die "Cannot mount ${target_part}"
    fi

    info "Mounting ISO..."
    iso_mount=$(mktemp -d)
    if ! mount -o loop,ro "$iso_file" "$iso_mount"; then
        rmdir "$iso_mount" 2>/dev/null || true
        iso_mount=""
        cleanup
        die "Cannot mount ISO: ${iso_file} (may be corrupted)"
    fi

    local casper_dir=""
    for dir in "$iso_mount/casper" "$iso_mount/live"; do
        if [[ -d "$dir" ]]; then
            casper_dir="$dir"
            break
        fi
    done

    if [[ -z "$casper_dir" ]]; then
        cleanup
        die "No casper/ or live/ directory found in ISO"
    fi

    local casper_name
    casper_name=$(basename "$casper_dir")

    mkdir -p "${mount_point}/${casper_name}"

    info "Copying ${casper_name}/vmlinuz..."
    if [[ -f "${casper_dir}/vmlinuz" ]]; then
        if ! cp "${casper_dir}/vmlinuz" "${mount_point}/${casper_name}/vmlinuz" 2>&1; then
            cleanup
            die "Failed to copy vmlinuz (ISO may be truncated/corrupted)"
        fi
    elif [[ -f "${casper_dir}/vmlinuz.efi" ]]; then
        if ! cp "${casper_dir}/vmlinuz.efi" "${mount_point}/${casper_name}/vmlinuz"; then
            cleanup
            die "Failed to copy vmlinuz.efi"
        fi
    else
        cleanup
        die "vmlinuz not found in ISO"
    fi

    info "Copying ${casper_name}/initrd.img..."
    if [[ -f "${casper_dir}/initrd.img" ]]; then
        if ! cp "${casper_dir}/initrd.img" "${mount_point}/${casper_name}/initrd.img"; then
            cleanup
            die "Failed to copy initrd.img"
        fi
    elif [[ -f "${casper_dir}/initrd.lz" ]]; then
        if ! cp "${casper_dir}/initrd.lz" "${mount_point}/${casper_name}/initrd.img"; then
            cleanup
            die "Failed to copy initrd.lz"
        fi
    else
        cleanup
        die "initrd not found in ISO"
    fi

    info "Copying ${casper_name}/filesystem.squashfs..."
    local squashfs_path=""
    for path in "$iso_mount/casper/filesystem.squashfs" "$iso_mount/live/filesystem.squashfs"; do
        if [[ -f "$path" ]]; then
            squashfs_path="$path"
            break
        fi
    done

    if [[ -n "$squashfs_path" ]]; then
        if ! cp "$squashfs_path" "${mount_point}/${casper_name}/filesystem.squashfs"; then
            cleanup
            die "Failed to copy filesystem.squashfs"
        fi
    else
        cleanup
        die "filesystem.squashfs not found in ISO"
    fi

    cleanup
    info "ISO content installed to ${target_label}"
}

cmd_install() {
    local device="$1"
    local iso_file="$2"
    local target="${3:-A}"

    [[ "$(id -u)" -eq 0 ]] || die "This command must be run as root (use sudo)"
    [[ -b "$device" ]] || die "${device} is not a block device"
    [[ -f "$iso_file" ]] || die "ISO file not found: ${iso_file}"

    local prefix
    prefix=$(get_part_prefix "$device")

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would install ISO ${iso_file} to System ${target} on ${device}"
        echo "[DRY-RUN]   - Target partition: ${prefix}$([[ "$target" =~ ^[Aa]$ ]] && echo "3" || echo "4")"
        echo "[DRY-RUN]   - Extract vmlinuz, initrd.img, filesystem.squashfs"
        echo "[DRY-RUN]   - Re-install GRUB (Legacy + UEFI)"
        return 0
    fi

    local target_label
    local target_part
    case "$target" in
        A|a)
            target_label="${SYSTEM_A_LABEL}"
            target_part="${prefix}3"
            ;;
        B|b)
            target_label="${SYSTEM_B_LABEL}"
            target_part="${prefix}4"
            ;;
        *)
            die "Invalid target: ${target}. Use A or B."
            ;;
    esac

    [[ -b "$target_part" ]] || die "Partition ${target_part} not found"

    local label
    label=$(blkid -s LABEL -o value "$target_part" 2>/dev/null || echo "")
    [[ "$label" == "$target_label" ]] || warn "Partition label is '${label}', expected '${target_label}'"

    echo "=== Magic Stick Install ==="
    echo "ISO:      ${iso_file}"
    echo "Device:   ${device}"
    echo "Target:   System ${target} (${target_part})"
    echo ""
    echo "This will write the ISO content to ${target_part}."
    echo "Data on this partition will be ERASED."
    echo "The persistence partition will NOT be touched."
    echo ""
    prompt_confirm || { echo "Aborted."; exit 0; }

    echo ""
    info "Unmounting target partition..."
    umount "${target_part}" 2>/dev/null || true

    extract_iso_to_partition "$iso_file" "$target_part" "$target_label"

    info "Re-installing GRUB (Legacy BIOS + UEFI)..."
    install_grub "$device"

    echo ""
    echo "=== Install complete! ==="
    echo "System ${target} has been installed on ${target_part}."
    echo ""
    echo "To switch the default boot partition:"
    echo "  sudo $0 switch ${device}"
}

cmd_update() {
    local device="$1"
    local iso_file="${2:-}"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would perform A/B update on ${device}"
        echo "[DRY-RUN]   - Detect active partition"
        echo "[DRY-RUN]   - Select inactive partition as target"
        echo "[DRY-RUN]   - Extract ISO contents to target partition"
        echo "[DRY-RUN]   - Switch GRUB default to target partition"
        echo "[DRY-RUN]   - Persistence partition left untouched"
        return 0
    fi

    [[ "$(id -u)" -eq 0 ]] || die "This command must be run as root (use sudo)"
    [[ -b "$device" ]] || die "${device} is not a block device"

    if [[ -z "$iso_file" ]]; then
        iso_file=$(ls -t "${BUILD_DIR}"/magic-stick_*.iso 2>/dev/null | head -1)
    fi

    [[ -f "$iso_file" ]] || die "No ISO file found. Run scripts/build.sh first."

    local prefix
    prefix=$(get_part_prefix "$device")

    local part_a="${prefix}3"
    local part_b="${prefix}4"

    echo "=== Magic Stick A/B Update ==="
    echo "ISO:    ${iso_file}"
    echo "Device: ${device}"
    echo ""

    for i in 1 2 3 4 5; do
        [[ -b "${prefix}${i}" ]] || die "Partition ${prefix}${i} not found. Run 'setup-ab' first."
    done

    local active
    active=$(detect_active_partition "$device")
    echo "Active partition: ${active}"

    local target_partition
    local target_label
    local target_part
    if [[ "$active" == "A" ]]; then
        target_partition="B"
        target_label="${SYSTEM_B_LABEL}"
        target_part="$part_b"
    else
        target_partition="A"
        target_label="${SYSTEM_A_LABEL}"
        target_part="$part_a"
    fi

    echo "Target: System ${target_partition} (${target_part})"
    echo ""
    echo "This will write the ISO content to ${target_part}."
    echo "The persistence partition will NOT be touched."
    echo ""
    prompt_confirm || { echo "Aborted."; exit 0; }

    echo ""
    info "Unmounting target partition..."
    umount "${target_part}" 2>/dev/null || true

    extract_iso_to_partition "$iso_file" "$target_part" "$target_label"

    info "Switching default boot to System ${target_partition}..."
    switch_grub_default "$device" "$target_partition"

    echo ""
    echo "=== Update complete! ==="
    echo "System ${target_partition} has been updated."
    echo "Default boot switched to System ${target_partition}."
    echo ""
    echo "Reboot to use the new system."
    echo "If it fails, select 'System ${active}' in the GRUB menu."
    echo ""
    echo "Persistence partition was NOT modified (user data safe)."
}

switch_grub_default() {
    local device="$1"
    local new_default="$2"

    local prefix
    prefix=$(get_part_prefix "$device")
    local part_a="${prefix}3"

    local mount_point
    mount_point=$(mktemp -d)

    mount "${part_a}" "$mount_point" 2>/dev/null || die "Cannot mount ${part_a}"
    trap 'sync; umount "${part_a}" 2>/dev/null || true; rmdir "$mount_point" 2>/dev/null || true' RETURN EXIT

    generate_grub_cfg "${mount_point}/boot/grub/grub.cfg" "$new_default"
}

cmd_switch() {
    local device="$1"

    [[ "$(id -u)" -eq 0 ]] || die "This command must be run as root (use sudo)"
    [[ -b "$device" ]] || die "${device} is not a block device"

    local prefix
    prefix=$(get_part_prefix "$device")
    local part_a="${prefix}3"

    local current_default
    current_default=$(read_grub_default "$device")

    local new_default
    if [[ "$current_default" == "A" ]]; then
        new_default="B"
    else
        new_default="A"
    fi

    echo "=== Switching default boot partition ==="
    echo "Device: ${device}"
    echo "Current default: System ${current_default}"
    echo "New default:     System ${new_default}"
    echo ""

    switch_grub_default "$device" "$new_default"

    echo "Default boot partition switched to System ${new_default}."
    echo "Reboot to boot from System ${new_default}."
}

cmd_verify() {
    local device="$1"

    [[ -b "$device" ]] || die "${device} is not a block device"

    local prefix
    prefix=$(get_part_prefix "$device")

    echo "=== Magic Stick A/B Verification ==="
    echo "Device: ${device}"
    echo ""

    local errors=0

    echo "[1/7] Checking partition table..."
    local pt_type
    pt_type=$(LANG=C parted -s "$device" print 2>/dev/null | grep "Partition Table:" | awk '{print $3}' || echo "")
    if [[ "$pt_type" == "gpt" ]]; then
        echo "  OK: GPT partition table"
    else
        echo "  FAIL: Expected GPT, got '${pt_type}'"
        ((errors++))
    fi

    echo "[2/7] Checking boot partitions..."
    local part_esp="${prefix}2"
    local part_biosgrub="${prefix}1"

    local esp_type
    esp_type=$(blkid -s TYPE -o value "$part_esp" 2>/dev/null || echo "")
    if [[ "$esp_type" == "vfat" ]]; then
        echo "  OK: ESP partition ${part_esp} is FAT32"
    else
        echo "  FAIL: ESP partition ${part_esp} type='${esp_type}' (expected vfat)"
        ((errors++))
    fi

    if [[ -b "$part_biosgrub" ]]; then
        echo "  OK: bios_grub partition ${part_biosgrub} exists"
    else
        echo "  FAIL: bios_grub partition ${part_biosgrub} not found"
        ((errors++))
    fi

    echo "[3/7] Checking UEFI bootloader on ESP..."
    if [[ -f "${mount_point:-/nonexistent}/EFI/BOOT/BOOTX64.EFI" ]]; then
        echo "  OK: BOOTX64.EFI found on ESP"
    else
        local esp_mount
        esp_mount=$(mktemp -d)
        if mount -o ro "$part_esp" "$esp_mount" 2>/dev/null; then
            if [[ -f "${esp_mount}/EFI/BOOT/BOOTX64.EFI" ]]; then
                echo "  OK: BOOTX64.EFI found on ESP"
            else
                echo "  WARN: BOOTX64.EFI not found on ESP (run install after flash)"
            fi
            umount "$esp_mount" 2>/dev/null || true
        else
            echo "  WARN: Cannot mount ESP"
        fi
        rmdir "$esp_mount" 2>/dev/null || true
    fi

    echo "[4/7] Checking partition labels..."
    local expected_labels=(2:"${ESP_LABEL}" 3:"${SYSTEM_A_LABEL}" 4:"${SYSTEM_B_LABEL}" 5:"${PERSISTENCE_LABEL}")

    for entry in "${expected_labels[@]}"; do
        local part_num="${entry%%:*}"
        local expected_label="${entry#*:}"
        local part="${prefix}${part_num}"

        if [[ ! -b "$part" ]]; then
            echo "  FAIL: Partition ${part} not found"
            ((errors++))
            continue
        fi
        local label
        label=$(blkid -s LABEL -o value "$part" 2>/dev/null || echo "")
        if [[ "$label" == "$expected_label" ]]; then
            echo "  OK: ${part} label=${label}"
        else
            echo "  FAIL: ${part} label='${label}' (expected '${expected_label}')"
            ((errors++))
        fi
    done

    echo "[5/7] Checking system partition contents..."
    for part_num in 3 4; do
        local part="${prefix}${part_num}"
        local part_label
        part_label=$(blkid -s LABEL -o value "$part" 2>/dev/null || echo "?")
        local mount_point
        mount_point=$(mktemp -d)
        if mount -o ro "$part" "$mount_point" 2>/dev/null; then
            trap 'umount "$part" 2>/dev/null || true; rmdir "$mount_point" 2>/dev/null || true' RETURN EXIT
            for f in casper/vmlinuz casper/initrd.img casper/filesystem.squashfs; do
                if [[ -f "${mount_point}/${f}" ]]; then
                    echo "  OK: ${part_label}/${f}"
                else
                    echo "  WARN: ${part_label}/${f} not found"
                fi
            done
        else
            echo "  WARN: Cannot mount ${part} (may be empty)"
            rmdir "$mount_point" 2>/dev/null || true
        fi
    done

    echo "[6/7] Checking persistence..."
    local part_p="${prefix}5"
    if [[ -b "$part_p" ]]; then
        local mount_point
        mount_point=$(mktemp -d)
        if mount -o ro "$part_p" "$mount_point" 2>/dev/null; then
            trap 'umount "$part_p" 2>/dev/null || true; rmdir "$mount_point" 2>/dev/null || true' RETURN EXIT
            if [[ -f "${mount_point}/persistence.conf" ]]; then
                echo "  OK: persistence.conf found"
            else
                echo "  WARN: persistence.conf not found"
            fi
        else
            echo "  WARN: Cannot mount persistence partition"
            rmdir "$mount_point" 2>/dev/null || true
        fi
    else
        echo "  FAIL: Persistence partition not found"
        ((errors++))
    fi

    echo "[7/7] Checking GRUB installation and core.img modules..."
    if command -v grub-install >/dev/null 2>&1; then
        echo "  OK: grub-install available"
    else
        echo "  WARN: grub-install not found"
    fi

    local part_a="${prefix}3"
    local mount_point
    mount_point=$(mktemp -d)
    if mount -o ro "$part_a" "$mount_point" 2>/dev/null; then
        if [[ -f "${mount_point}/boot/grub/grub.cfg" ]]; then
            echo "  OK: grub.cfg found on system_a"
            if grep -q "gfxterm" "${mount_point}/boot/grub/grub.cfg" 2>/dev/null; then
                echo "  OK: grub.cfg uses gfxterm (graphical menu)"
            else
                echo "  WARN: grub.cfg may use serial output (no gfxterm)"
            fi
        else
            echo "  FAIL: grub.cfg not found on system_a"
            ((errors++))
        fi

        if [[ -f "${mount_point}/boot/grub/i386-pc/core.img" ]]; then
            local core_size
            core_size=$(stat -c%s "${mount_point}/boot/grub/i386-pc/core.img" 2>/dev/null || echo 0)
            if [[ "$core_size" -gt 100000 ]]; then
                echo "  OK: core.img is ${core_size} bytes (modules embedded: ext2, gfxterm, etc.)"
            else
                echo "  FAIL: core.img is only ${core_size} bytes — modules NOT embedded, GRUB will drop to prompt"
                ((errors++))
            fi
        else
            echo "  WARN: core.img not found (may be in bios_grub partition)"
        fi

        if [[ -f "${mount_point}/boot/grub/x86_64-efi/core.efi" ]]; then
            local efi_size
            efi_size=$(stat -c%s "${mount_point}/boot/grub/x86_64-efi/core.efi" 2>/dev/null || echo 0)
            if [[ "$efi_size" -gt 1000000 ]]; then
                echo "  OK: UEFI core.efi is ${efi_size} bytes (modules embedded)"
            else
                echo "  WARN: UEFI core.efi is only ${efi_size} bytes — modules may be missing"
            fi
        else
            echo "  WARN: UEFI core.efi not found on system_a (check ESP)"
        fi
        umount "$part_a" 2>/dev/null || true
    else
        echo "  WARN: Cannot mount system_a for GRUB check"
    fi
    rmdir "$mount_point" 2>/dev/null || true

    echo ""
    if [[ "$errors" -eq 0 ]]; then
        echo "=== Verification passed ==="
    else
        echo "=== Verification completed with ${errors} error(s) ==="
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)
            FORCE_YES=true
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
    setup-ab)
        cmd_setup_ab "$@"
        ;;
    install)
        cmd_install "$@"
        ;;
    update)
        cmd_update "$@"
        ;;
    switch)
        cmd_switch "$@"
        ;;
    status)
        cmd_status "$1"
        ;;
    verify)
        cmd_verify "$1"
        ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown command: ${COMMAND}"
        usage
        exit 1
        ;;
esac
