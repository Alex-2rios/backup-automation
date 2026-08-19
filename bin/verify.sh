#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${BACKUP_CONFIG:-${SCRIPT_DIR}/../etc/backup.conf}"

DRILL=0
[ "${1:-}" = "--drill" ] && DRILL=1

if [ ! -f "$CONFIG_FILE" ]; then
    printf 'no config at %s\n' "$CONFIG_FILE" >&2
    exit 1
fi

. "$CONFIG_FILE"

checked=0
failed=0
newest=""

check_directory() {
    local directory="$1" role="$2" archive base

    if [ -z "$directory" ]; then
        return 0
    fi

    if [ ! -d "$directory" ]; then
        printf '%-10s %s is not available\n' "$role" "$directory"
        failed=$((failed + 1))
        return 0
    fi

    printf '\n%s: %s\n' "$role" "$directory"

    while IFS= read -r archive; do
        base="$(basename "$archive")"
        checked=$((checked + 1))

        if [ ! -f "$archive.sha256" ]; then
            printf '  [FAIL] %-52s no checksum file\n' "$base"
            failed=$((failed + 1))
            continue
        fi

        if ! ( cd "$directory" && sha256sum -c --status "$base.sha256" ); then
            printf '  [FAIL] %-52s checksum mismatch\n' "$base"
            failed=$((failed + 1))
            continue
        fi

        if ! tar -tf "$archive" > /dev/null 2>&1; then
            printf '  [FAIL] %-52s archive is unreadable\n' "$base"
            failed=$((failed + 1))
            continue
        fi

        printf '  [ ok ] %-52s %s\n' "$base" "$(du -h "$archive" | cut -f1)"
        newest="$archive"
    done < <(find "$directory" -maxdepth 1 -name "${JOB_NAME}-*" ! -name '*.sha256' | sort)
}

restore_drill() {
    local archive="$1" workdir extracted

    [ -n "$archive" ] || return 0

    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' RETURN

    printf '\nrestore drill on %s\n' "$(basename "$archive")"

    if ! tar -xf "$archive" -C "$workdir" 2>/dev/null; then
        printf '  [FAIL] extraction failed\n'
        failed=$((failed + 1))
        return 1
    fi

    extracted="$(find "$workdir" -type f | wc -l)"
    printf '  [ ok ] extracted %s files into a temporary directory\n' "$extracted"

    if [ "$extracted" -eq 0 ]; then
        printf '  [FAIL] the archive restored zero files\n'
        failed=$((failed + 1))
        return 1
    fi
}

printf 'verifying backups for %s\n' "$JOB_NAME"

check_directory "$PRIMARY_DIR" "primary"
check_directory "${SECONDARY_DIR:-}" "secondary"

if [ "$DRILL" -eq 1 ]; then
    restore_drill "$newest"
fi

printf '\n%s archives checked, %s problems\n' "$checked" "$failed"

if [ -f "${PRIMARY_DIR}/${JOB_NAME}.state" ]; then
    printf '\nlast run\n'
    sed 's/^/  /' "${PRIMARY_DIR}/${JOB_NAME}.state"
fi

[ "$failed" -eq 0 ]
