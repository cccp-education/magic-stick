#!/usr/bin/env python3
"""Patch lb_chroot_devpts to also bind-mount /dev into chroot (overlay2 lacks device nodes)."""
import sys
import os

SCRIPT = sys.argv[1] if len(sys.argv) > 1 else "/usr/lib/live/build/lb_chroot_devpts"

if not os.path.isfile(SCRIPT):
    print(f"SKIP: {SCRIPT} not found")
    sys.exit(0)

with open(SCRIPT, 'r', encoding='utf-8') as f:
    content = f.read()

mount_marker = 'mkdir -p chroot/dev/pts\n\n\t\t\t# Mounting /dev/pts'
mount_block = '''mkdir -p chroot/dev/pts

			# Bind-mount /dev into chroot (overlay2 lacks device nodes)
			mount --bind /dev chroot/dev 2>/dev/null || true

			# Mounting /dev/pts'''

if mount_marker in content and mount_block.strip() not in content:
    content = content.replace(mount_marker, mount_block)
    print("PATCHED: bind-mount /dev into chroot (install)")

unmount_marker = 'if grep -qs "$(pwd)/chroot/dev/pts" /proc/mounts || Find_files chroot/dev/pts/*'
unmount_block = '''# Unmount /dev bind-mount first
			umount chroot/dev 2>/dev/null || true

			if grep -qs "$(pwd)/chroot/dev/pts" /proc/mounts || Find_files chroot/dev/pts/*'''

if unmount_marker in content and unmount_block.strip() not in content:
    content = content.replace(unmount_marker, unmount_block)
    print("PATCHED: unmount /dev from chroot (remove)")

with open(SCRIPT, 'w', encoding='utf-8') as f:
    f.write(content)
print(f"PATCHED: {SCRIPT}")
