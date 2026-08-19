#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${BACKUP_CONFIG:-${SCRIPT_DIR}/../etc/backup.conf}"

usage() {
    cat <<USAGE
usage: restore.sh [--list] [--archive FILE] --to DIRECTORY

  --list            show the archives available, newest last
  --archive FILE    restore this archive, defaults to the newest one
  --to DIRECTORY    where to extract, it must be empty or not exist yet
USAGE
    exit "${1:-0}"
}

[ -f "$CONFIG_FILE" ] || { printf 'no config at %s\n' "$CONFIG_FILE" >&2; exit 1; }
. "$CONFIG_FILE"

ARCHIVE=""
TARGET=""
LIST=0

while [ $# -gt 0 ]; do
    case "$1" in
        --list) LIST=1; shift ;;
        --archive) ARCHIVE="${2:-}"; shift 2 ;;
        --to) TARGET="${2:-}"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) printf 'unknown argument %s\n' "$1" >&2; usage 2 ;;
    esac
done

available() {
    find "$PRIMARY_DIR" -maxdepth 1 -name "${JOB_NAME}-*" ! -name '*.sha256' | sort
}

if [ "$LIST" -eq 1 ]; then
    printf 'archives in %s\n\n' "$PRIMARY_DIR"
    while IFS= read -r file; do
        printf '  %-58s %s\n' "$(basename "$file")" "$(du -h "$file" | cut -f1)"
    done < <(available)
    exit 0
fi

[ -n "$TARGET" ] || usage 2

if [ -z "$ARCHIVE" ]; then
    ARCHIVE="$(available | tail -1)"
    [ -n "$ARCHIVE" ] || { printf 'no archives found in %s\n' "$PRIMARY_DIR" >&2; exit 1; }
    printf 'no archive given, using the newest: %s\n' "$(basename "$ARCHIVE")"
fi

[ -f "$ARCHIVE" ] || { printf '%s does not exist\n' "$ARCHIVE" >&2; exit 1; }

if [ -d "$TARGET" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null)" ]; then
    printf '%s is not empty, refusing to extract on top of it\n' "$TARGET" >&2
    exit 1
fi

printf 'checking the archive before restoring\n'
if [ -f "$ARCHIVE.sha256" ]; then
    ( cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$ARCHIVE").sha256" )
else
    printf 'warning: no checksum file next to this archive\n' >&2
fi

mkdir -p "$TARGET"
tar -xf "$ARCHIVE" -C "$TARGET"

printf '\nrestored %s files into %s\n' "$(find "$TARGET" -type f | wc -l)" "$TARGET"
