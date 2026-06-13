#!/usr/bin/env python3
"""Patch lb_chroot_apt to bind-mount /dev into chroot for apt-key, then unmount after."""
import sys
import os

SCRIPT = sys.argv[1] if len(sys.argv) > 1 else "/usr/lib/live/build/lb_chroot_apt"

if not os.path.isfile(SCRIPT):
    print(f"SKIP: {SCRIPT} not found")
    sys.exit(0)

with open(SCRIPT, 'r', encoding='utf-8') as f:
    content = f.read()

insert_marker = 'mkdir -p chroot/etc/apt/apt.conf.d'
fix_block = '''mkdir -p chroot/tmp && chmod 1777 chroot/tmp
mkdir -p chroot/dev && mount --bind /dev chroot/dev 2>/dev/null || true

'''

if insert_marker in content and fix_block.strip() not in content:
    content = content.replace(insert_marker, fix_block + insert_marker)
    print("PATCHED: mount /dev into chroot before apt-key")

unmount_marker = 'Create_stagefile .build/chroot_apt'
unmount_block = '''umount chroot/dev 2>/dev/null || true

Create_stagefile .build/chroot_apt'''

if unmount_marker in content and unmount_block.strip() not in content:
    content = content.replace(unmount_marker, unmount_block)
    print("PATCHED: unmount /dev from chroot after apt-key")

with open(SCRIPT, 'w', encoding='utf-8') as f:
    f.write(content)
print(f"PATCHED: {SCRIPT}")
