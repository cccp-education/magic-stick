#!/usr/bin/env python3
"""Patch lb_chroot_apt to ensure chroot /tmp is writable for apt-key (GPG transient workaround)."""
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
mkdir -p chroot/dev chroot/dev/pts && mount --bind /dev chroot/dev 2>/dev/null || true
mkdir -p chroot/dev/pts && mount --bind /dev/pts chroot/dev/pts 2>/dev/null || true

'''

if insert_marker in content and fix_block.strip() not in content:
    content = content.replace(insert_marker, fix_block + insert_marker)
    with open(SCRIPT, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f"PATCHED: {SCRIPT} — chroot /tmp writable before apt-key")
else:
    print(f"SKIP: {SCRIPT} already patched or marker not found")
