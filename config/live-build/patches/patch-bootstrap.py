#!/usr/bin/env python3
"""Patch lb_bootstrap_debootstrap to create essential /dev nodes and /tmp in chroot before debootstrap."""
import sys
import os

SCRIPT = sys.argv[1] if len(sys.argv) > 1 else "/usr/lib/live/build/lb_bootstrap_debootstrap"

if not os.path.isfile(SCRIPT):
    print(f"SKIP: {SCRIPT} not found")
    sys.exit(0)

with open(SCRIPT, 'r', encoding='utf-8') as f:
    content = f.read()

insert_marker = 'mkdir -p chroot\n\n# Setting debootstrap options'
fix_block = '''mkdir -p chroot

# Ensure chroot has essential /dev nodes and writable /tmp (GPG transient workaround)
mkdir -p chroot/dev chroot/tmp && chmod 1777 chroot/tmp
mknod -m 666 chroot/dev/null c 1 3 2>/dev/null || true
mknod -m 666 chroot/dev/zero c 1 5 2>/dev/null || true
mknod -m 444 chroot/dev/urandom c 1 9 2>/dev/null || true
mkdir -p chroot/dev/pts && mknod -m 666 chroot/dev/ptmx c 5 2 2>/dev/null || true

# Setting debootstrap options'''

if insert_marker in content and fix_block.strip() not in content:
    content = content.replace(insert_marker, fix_block)
    with open(SCRIPT, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f"PATCHED: {SCRIPT} — chroot /dev + /tmp before debootstrap")
else:
    print(f"SKIP: {SCRIPT} already patched or marker not found")
