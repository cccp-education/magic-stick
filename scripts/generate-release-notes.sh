#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# generate-release-notes.sh — Generate AsciiDoc release notes from git history
#
# Usage:
#   ./scripts/generate-release-notes.sh [--from-tag <tag>] [--to-tag <tag>] [--output <file>]
#
# Default behavior:
#   - Finds the latest two git tags, generates notes between them
#   - If only one tag exists, generates notes from first commit
#   - Outputs to stdout or specified file in AsciiDoc format
#
# Can be extended with Ollama for AI-generated summaries (EPIC 7.2).
# ------------------------------------------------------------------------------
set -euo pipefail

FROM_TAG=""
TO_TAG=""
OUTPUT_FILE=""

usage() {
    cat <<EOF
Usage: $0 [--from-tag <tag>] [--to-tag <tag>] [--output <file>]

Options:
  --from-tag <tag>   Start from this tag (defaults to previous tag)
  --to-tag <tag>     End at this tag (defaults to HEAD)
  --output <file>    Write to file instead of stdout
  --help             Show this help

Example:
  $0 --from-tag v0.1.8 --to-tag v0.1.14
  $0 --to-tag v0.1.14 --output releases.adoc
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from-tag) FROM_TAG="$2"; shift 2 ;;
        --to-tag)   TO_TAG="$2"; shift 2 ;;
        --output)   OUTPUT_FILE="$2"; shift 2 ;;
        --help)     usage ;;
        *)          echo "Unknown option: $1"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION_FILE="$REPO_ROOT/VERSION"
VERSION=""
if [[ -f "$VERSION_FILE" ]]; then
    VERSION=$(head -n 1 "$VERSION_FILE" | tr -d '[:space:]')
fi

if [[ -z "$TO_TAG" ]]; then
    if [[ -n "$VERSION" ]] && git -C "$REPO_ROOT" rev-parse "v${VERSION}" >/dev/null 2>&1; then
        TO_TAG="v${VERSION}"
    else
        TO_TAG="HEAD"
    fi
fi

if [[ -z "$FROM_TAG" ]]; then
    FROM_TAG=$(git -C "$REPO_ROOT" describe --tags --abbrev=0 "${TO_TAG}^" 2>/dev/null || echo "")
fi

TO_DATE=$(git -C "$REPO_ROOT" log -1 --format=%ad --date=short "$TO_TAG" 2>/dev/null || date +%Y-%m-%d)

declare -A CATEGORIES
CATEGORIES=(
    ["feat"]="Nouveautes"
    ["fix"]="Corrections"
    ["chore"]="Maintenance"
    ["perf"]="Performance"
    ["refactor"]="Refactoring"
    ["docs"]="Documentation"
    ["test"]="Tests"
)

generate() {
    TO_VER=$(echo "$TO_TAG" | sed 's/^v//')
    cat <<ASCIIDOC
= Notes de version Magic Stick v${TO_VER}
:date: ${TO_DATE}
:type: page
:status: published
~~~~~~

== Version ${TO_VER} — ${TO_DATE}

ASCIIDOC

    if [[ -n "$FROM_TAG" ]]; then
        FROM_DATE=$(git -C "$REPO_ROOT" log -1 --format=%ad --date=short "$FROM_TAG" 2>/dev/null || echo "debut")
        echo ""
        echo "Commits depuis ${FROM_TAG} (${FROM_DATE}) jusqu'a ${TO_TAG} (${TO_DATE})."
    fi

    echo ""

    HAS_COMMITS=false
    for prefix in feat fix chore perf refactor docs test; do
        COMMITS=$(git -C "$REPO_ROOT" log --oneline --no-merges --format="%s" "${FROM_TAG}..${TO_TAG}" 2>/dev/null | grep -i "^${prefix}[:(]" || true)
        if [[ -n "$COMMITS" ]]; then
            HAS_COMMITS=true
            echo "=== ${CATEGORIES[$prefix]}"
            echo ""
            while IFS= read -r line; do
                MSG=$(echo "$line" | sed -E 's/^[a-zA-Z]+[(:] *//; s/\)?:? *//')
                echo "* ${MSG}"
            done <<< "$COMMITS"
            echo ""
        fi
    done

    if [[ "$HAS_COMMITS" == "false" ]]; then
        echo "Aucun commit conventionnel trouve entre ${FROM_TAG} et ${TO_TAG}."
        echo ""
    fi

    cat <<ASCIIDOC
=== Telechargement

[cols="1,3"]
|===
| Artifact | Lien
| ISO | link:https://sourceforge.net/projects/magic-stick/files/magic-stick_${TO_VER}.iso/[magic-stick_${TO_VER}.iso]
| SHA256 | link:https://sourceforge.net/projects/magic-stick/files/magic-stick_${TO_VER}.iso.sha256/[magic-stick_${TO_VER}.iso.sha256]
| Docker CLI | link:https://hub.docker.com/r/cccpeducation/magic-stick-cli[cccpeducation/magic-stick-cli:${TO_VER}]
| Depot | link:https://github.com/cccp-education/magic-stick[github.com/cccp-education/magic-stick]
|===
ASCIIDOC
}

if [[ -n "$OUTPUT_FILE" ]]; then
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    generate > "$OUTPUT_FILE"
    echo "Release notes generated: $OUTPUT_FILE"
else
    generate
fi
