#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${BACKUP_CONFIG:-${SCRIPT_DIR}/../etc/backup.conf}"

declare -i EXIT_CODE=0

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        printf 'no config at %s, copy etc/backup.conf.example and edit it\n' "$CONFIG_FILE" >&2
        exit 1
    fi

    . "$CONFIG_FILE"

    : "${JOB_NAME:?JOB_NAME is required}"
    : "${SOURCES:?SOURCES is required}"
    : "${PRIMARY_DIR:?PRIMARY_DIR is required}"

    SECONDARY_DIR="${SECONDARY_DIR:-}"
    REMOTE_TARGET="${REMOTE_TARGET:-}"
    LOG_FILE="${LOG_FILE:-${PRIMARY_DIR}/backup.log}"
    KEEP_DAILY="${KEEP_DAILY:-7}"
    KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
    KEEP_MONTHLY="${KEEP_MONTHLY:-6}"
    COMPRESSION="${COMPRESSION:-gzip}"
    EXCLUDES="${EXCLUDES:-}"
}

log() {
    local level="$1"
    shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
    printf '%s\n' "$line" >&2
    printf '%s\n' "$line" >> "$LOG_FILE"
}

die() {
    log error "$*"
    exit 2
}

acquire_lock() {
    LOCK_DIR="${PRIMARY_DIR}/.${JOB_NAME}.lock"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log error "another run holds $LOCK_DIR, giving up"
        exit 3
    fi
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
}

current_tier() {
    local day_of_month day_of_week
    day_of_month="$(date '+%d')"
    day_of_week="$(date '+%u')"

    if [ "$day_of_month" = "01" ]; then
        printf 'monthly'
    elif [ "$day_of_week" = "7" ]; then
        printf 'weekly'
    else
        printf 'daily'
    fi
}

compression_flag() {
    case "$COMPRESSION" in
        gzip) printf -- '-z' ;;
        bzip2) printf -- '-j' ;;
        xz) printf -- '-J' ;;
        none) printf '' ;;
        *) die "unknown COMPRESSION '$COMPRESSION'" ;;
    esac
}

archive_suffix() {
    case "$COMPRESSION" in
        gzip) printf 'tar.gz' ;;
        bzip2) printf 'tar.bz2' ;;
        xz) printf 'tar.xz' ;;
        none) printf 'tar' ;;
    esac
}

build_exclude_args() {
    EXCLUDE_ARGS=()
    local pattern
    for pattern in $EXCLUDES; do
        EXCLUDE_ARGS+=("--exclude=$pattern")
    done
}

create_archive() {
    local source="$1" tier="$2" stamp="$3"
    local label archive flag

    if [ ! -e "$source" ]; then
        log error "source $source does not exist, skipping"
        return 1
    fi

    label="$(printf '%s' "$source" | sed 's#^/##; s#[/ ]#_#g; s#:##g')"
    archive="${PRIMARY_DIR}/${JOB_NAME}-${label}-${stamp}-${tier}.$(archive_suffix)"
    flag="$(compression_flag)"

    log info "archiving $source"

    if [ -n "$flag" ]; then
        tar "$flag" -cf "$archive" "${EXCLUDE_ARGS[@]}" -C "$(dirname "$source")" "$(basename "$source")"
    else
        tar -cf "$archive" "${EXCLUDE_ARGS[@]}" -C "$(dirname "$source")" "$(basename "$source")"
    fi

    ( cd "$(dirname "$archive")" && sha256sum "$(basename "$archive")" > "$(basename "$archive").sha256" )

    local size
    size="$(du -h "$archive" | cut -f1)"
    log info "wrote $(basename "$archive") ($size)"
    printf '%s' "$archive"
}

verify_archive() {
    local archive="$1"

    if ! ( cd "$(dirname "$archive")" && sha256sum -c --status "$(basename "$archive").sha256" ); then
        log error "checksum mismatch on $(basename "$archive")"
        return 1
    fi

    if ! tar -tf "$archive" > /dev/null 2>&1; then
        log error "$(basename "$archive") is not a readable archive"
        return 1
    fi

    log info "verified $(basename "$archive")"
}

copy_to_secondary() {
    local archive="$1"

    [ -n "$SECONDARY_DIR" ] || return 0

    if [ ! -d "$SECONDARY_DIR" ]; then
        log error "secondary target $SECONDARY_DIR is not mounted, copy skipped"
        EXIT_CODE=5
        return 1
    fi

    cp "$archive" "$archive.sha256" "$SECONDARY_DIR/"

    if ( cd "$SECONDARY_DIR" && sha256sum -c --status "$(basename "$archive").sha256" ); then
        log info "copied to secondary $SECONDARY_DIR and verified there"
    else
        log error "copy to $SECONDARY_DIR is corrupt"
        EXIT_CODE=5
        return 1
    fi
}

push_offsite() {
    local archive="$1"

    [ -n "$REMOTE_TARGET" ] || return 0

    if command -v rsync > /dev/null 2>&1; then
        if rsync -a --partial "$archive" "$archive.sha256" "$REMOTE_TARGET/"; then
            log info "pushed offsite to $REMOTE_TARGET"
            return 0
        fi
    elif command -v rclone > /dev/null 2>&1; then
        if rclone copy "$archive" "$REMOTE_TARGET"; then
            log info "pushed offsite with rclone to $REMOTE_TARGET"
            return 0
        fi
    else
        log error "neither rsync nor rclone is installed, offsite copy skipped"
        EXIT_CODE=6
        return 1
    fi

    log error "offsite push to $REMOTE_TARGET failed"
    EXIT_CODE=6
    return 1
}

prune_tier() {
    local directory="$1" tier="$2" keep="$3"
    local count removed=0 file

    [ -d "$directory" ] || return 0

    count="$(find "$directory" -maxdepth 1 -name "${JOB_NAME}-*-${tier}.*" ! -name '*.sha256' | wc -l)"
    [ "$count" -gt "$keep" ] || return 0

    while IFS= read -r file; do
        rm -f "$file" "$file.sha256"
        removed=$((removed + 1))
    done < <(find "$directory" -maxdepth 1 -name "${JOB_NAME}-*-${tier}.*" ! -name '*.sha256' \
        | sort | head -n "$((count - keep))")

    log info "pruned $removed old $tier archives from $directory"
}

prune_all() {
    local directory
    for directory in "$PRIMARY_DIR" "$SECONDARY_DIR"; do
        [ -n "$directory" ] || continue
        prune_tier "$directory" daily "$KEEP_DAILY"
        prune_tier "$directory" weekly "$KEEP_WEEKLY"
        prune_tier "$directory" monthly "$KEEP_MONTHLY"
    done
}

write_state() {
    local stamp="$1" tier="$2" archives="$3"
    local state="${PRIMARY_DIR}/${JOB_NAME}.state"

    {
        printf 'last_run=%s\n' "$stamp"
        printf 'tier=%s\n' "$tier"
        printf 'archives=%s\n' "$archives"
        printf 'exit_code=%s\n' "$EXIT_CODE"
        printf 'primary=%s\n' "$PRIMARY_DIR"
        printf 'secondary=%s\n' "${SECONDARY_DIR:-none}"
        printf 'offsite=%s\n' "${REMOTE_TARGET:-none}"
    } > "$state"
}

main() {
    load_config

    mkdir -p "$PRIMARY_DIR"
    touch "$LOG_FILE"

    acquire_lock
    build_exclude_args

    local stamp tier archive_count=0 source archive
    stamp="$(date '+%Y%m%d-%H%M%S')"
    tier="$(current_tier)"

    log info "starting $JOB_NAME, tier $tier"

    for source in $SOURCES; do
        if ! archive="$(create_archive "$source" "$tier" "$stamp")"; then
            EXIT_CODE=4
            continue
        fi

        if ! verify_archive "$archive"; then
            EXIT_CODE=2
            continue
        fi

        copy_to_secondary "$archive" || true
        push_offsite "$archive" || true
        archive_count=$((archive_count + 1))
    done

    prune_all
    write_state "$stamp" "$tier" "$archive_count"

    if [ "$EXIT_CODE" -eq 0 ]; then
        log info "finished, $archive_count archives written to all configured copies"
    else
        log error "finished with problems, exit code $EXIT_CODE"
    fi

    exit "$EXIT_CODE"
}

main "$@"
