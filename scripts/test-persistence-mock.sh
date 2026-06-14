#!/usr/bin/env bash
set -euo pipefail

# Magic Stick — Persistence Survival Mock Test
# Valide statiquement que update-system.sh ne touche jamais la partition
# persistence (n°5 / label persistence) hors du setup initial.
# Ce test est concu pour les runners CI/CD non-privileged (pas de loop device).
#
# Usage: ./test-persistence-mock.sh [path/to/update-system.sh]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_SCRIPT="${1:-${SCRIPT_DIR}/update-system.sh}"

ERRORS=0
die()  { echo "ERROR: $*" >&2; ((ERRORS++)); }
pass() { echo "  [OK] $*"; }
warn() { echo "  [WARN] $*" >&2; }
fail() { echo "  [FAIL] $*" >&2; ((ERRORS++)); }
info() { echo "==> $*"; }

[[ -f "$UPDATE_SCRIPT" ]] || die "File not found: $UPDATE_SCRIPT"

info "Running persistence survival mock test on ${UPDATE_SCRIPT} (v0.3.0+ layout: p5=persistence)"
echo ""

# 1. Syntax check
info "[1/6] Syntax check"
if bash -n "$UPDATE_SCRIPT"; then
    pass "bash -n OK"
else
    fail "bash -n FAILED"
fi
echo ""

# 2. Verify PERSISTENCE_LABEL is defined and equals "persistence"
info "[2/6] PERSISTENCE_LABEL definition"
LABEL=$(grep -E '^PERSISTENCE_LABEL=' "$UPDATE_SCRIPT" | head -1 | cut -d= -f2 | tr -d '"')
if [[ "$LABEL" == "persistence" ]]; then
    pass "PERSISTENCE_LABEL='persistence'"
else
    fail "PERSISTENCE_LABEL missing or unexpected value: '${LABEL}'"
fi
echo ""

# 3. grep for dangerous commands targeting partition 5 OUTSIDE setup context
# We exclude cmd_setup_ab (which legitimately formats p5 during initial setup)
info "[3/6] No destructive commands on persistence partition (p5) outside setup"

SETUP_AB_START=$(grep -n 'cmd_setup_ab()' "$UPDATE_SCRIPT" | head -1 | cut -d: -f1)
SETUP_AB_END=$(awk -v start="$SETUP_AB_START" 'NR>=start && /^}/ {print NR; exit}' "$UPDATE_SCRIPT")

TMP_SCRIPT=$(mktemp)
awk -v start="$SETUP_AB_START" -v end="$SETUP_AB_END" 'NR < start || NR > end' "$UPDATE_SCRIPT" > "$TMP_SCRIPT"

PATTERNS=(
    'mkfs.*persistence'
    'mkfs.*\\b${prefix}5\\b'
    'mkfs.*\\bp5\\b'
    'parted.*mkpart.*persistence'
    'dd .*\\b${prefix}5\\b'
    'dd .*\\bp5\\b'
)

for pat in "${PATTERNS[@]}"; do
    if grep -qE "$pat" "$TMP_SCRIPT"; then
        grep -nE "$pat" "$TMP_SCRIPT" | while read -r line; do
            fail "Forbidden pattern outside setup: ${line}"
        done
    fi
done

if [[ "$ERRORS" -eq 0 ]]; then
    pass "No destructive command found outside cmd_setup_ab"
fi
echo ""

# 4. Verify mount/umount of partition 5 is read-only (ro) outside setup
info "[4/6] Partition 5 mount is read-only outside setup"
AWK_SCRIPT='
NR >= start && NR <= end {next}
/mount.*\${prefix}5/ || /mount.*p5/ {
    if ($0 !~ /-o[[:space:]]+ro/) {
        print NR": "$0
    }
}'
MOUNT_RW=$(awk -v start="$SETUP_AB_START" -v end="$SETUP_AB_END" "$AWK_SCRIPT" "$UPDATE_SCRIPT" || true)
if [[ -n "$MOUNT_RW" ]]; then
    echo "$MOUNT_RW" | while read -r line; do
        fail "Partition 5 mounted without -o ro outside setup: ${line}"
    done
else
    pass "Partition 5 is never mounted rw outside cmd_setup_ab"
fi
echo ""

# 5. Verify cmd_install and cmd_update only target partitions 3 and 4
info "[5/6] cmd_install / cmd_update target only partitions 3 and 4"

for func in cmd_install cmd_update; do
    FUNC_START=$(grep -n "^${func}()" "$UPDATE_SCRIPT" | head -1 | cut -d: -f1)
    FUNC_END=$(awk -v start="$FUNC_START" 'NR>=start && /^}/ {print NR; exit}' "$UPDATE_SCRIPT")
    
    FUNC_BODY=$(mktemp)
    awk -v start="$FUNC_START" -v end="$FUNC_END" 'NR >= start && NR <= end' "$UPDATE_SCRIPT" > "$FUNC_BODY"
    
    if grep -vE '^[[:space:]]*(echo|cat|#)' "$FUNC_BODY" | grep -qE '\${prefix}5|\bp5\b|persistence.*partition|partition.*persistence'; then
        fail "${func} references partition 5 or persistence"
        grep -nE '\${prefix}5|\bp5\b|persistence.*partition|partition.*persistence' "$FUNC_BODY" | while read -r line; do
            echo "      ${line}"
        done
    else
        pass "${func} does not reference partition 5"
    fi
    
    rm -f "$FUNC_BODY"
done
echo ""

# 6. Verify user-facing messages confirm persistence is safe
info "[6/6] User-facing messages confirm persistence safety"
MESSAGES=(
    "The persistence partition will NOT be touched"
    "Persistence partition was NOT modified"
    "User data (never touched by updates)"
)
FOUND=0
for msg in "${MESSAGES[@]}"; do
    if grep -qF "$msg" "$UPDATE_SCRIPT"; then
        pass "Message found: '${msg}'"
        FOUND=$((FOUND + 1))
    fi
done

if [[ "$FOUND" -eq 0 ]]; then
    warn "No persistence safety message found — consider adding one"
fi
echo ""

rm -f "$TMP_SCRIPT"

echo "=== Persistence Survival Mock Test ==="
if [[ "$ERRORS" -eq 0 ]]; then
    echo "Result: ALL CHECKS PASSED"
    echo "  update-system.sh does not touch persistence partition outside setup."
    exit 0
else
    echo "Result: ${ERRORS} CHECK(S) FAILED"
    exit 1
fi
