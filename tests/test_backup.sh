#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0

ok() {
    printf '  [ ok ] %s\n' "$1"
    passed=$((passed + 1))
}

bad() {
    printf '  [FAIL] %s\n' "$1"
    failed=$((failed + 1))
}

assert_equal() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi
}

assert_true() {
    if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1 (exit code $2)"; fi
}

assert_false() {
    if [ "$2" -ne 0 ]; then ok "$1"; else bad "$1 (expected a non zero exit)"; fi
}

count_archives() {
    find "$1" -maxdepth 1 -name 'testjob-*' ! -name '*.sha256' 2>/dev/null | wc -l | tr -d ' '
}

setup() {
    mkdir -p "$WORK/source/docs" "$WORK/source/cache" "$WORK/primary" "$WORK/secondary"

    printf 'the important document\n' > "$WORK/source/docs/report.txt"
    printf 'configuration values\n' > "$WORK/source/docs/settings.conf"
    head -c 20000 /dev/urandom > "$WORK/source/docs/blob.bin"
    printf 'disposable\n' > "$WORK/source/cache/session.tmp"

    cat > "$WORK/backup.conf" <<CONF
JOB_NAME="testjob"
SOURCES="$WORK/source"
EXCLUDES="*.tmp"
PRIMARY_DIR="$WORK/primary"
SECONDARY_DIR="$WORK/secondary"
REMOTE_TARGET=""
LOG_FILE="$WORK/backup.log"
KEEP_DAILY=3
KEEP_WEEKLY=2
KEEP_MONTHLY=2
COMPRESSION="gzip"
CONF

    export BACKUP_CONFIG="$WORK/backup.conf"
}

printf 'backup-automation test suite\n\n'
setup

printf 'a backup run\n'
"$ROOT/bin/backup.sh" > "$WORK/run1.log" 2>&1
assert_true "the script exits cleanly" $?
assert_equal "one archive lands in the primary copy" "$(count_archives "$WORK/primary")" "1"
assert_equal "one archive lands in the secondary copy" "$(count_archives "$WORK/secondary")" "1"

ARCHIVE="$(find "$WORK/primary" -name 'testjob-*' ! -name '*.sha256' | head -1)"
[ -f "$ARCHIVE.sha256" ] && ok "a checksum file is written" || bad "a checksum file is written"

printf '\narchive contents\n'
tar -tf "$ARCHIVE" | grep -q 'docs/report.txt'
assert_true "the source files are inside" $?
tar -tf "$ARCHIVE" | grep -q 'session.tmp'
assert_false "excluded patterns are left out" $?

printf '\nverification\n'
"$ROOT/bin/verify.sh" > "$WORK/verify1.log" 2>&1
assert_true "verify passes on a healthy set" $?

printf '\ncorruption is detected\n'
cp "$ARCHIVE" "$WORK/pristine.tar.gz"
printf 'corrupted' >> "$ARCHIVE"
"$ROOT/bin/verify.sh" > "$WORK/verify2.log" 2>&1
assert_false "verify fails after a byte is appended" $?
grep -q 'checksum mismatch' "$WORK/verify2.log"
assert_true "it says the checksum did not match" $?
cp "$WORK/pristine.tar.gz" "$ARCHIVE"

printf '\nrestore\n'
"$ROOT/bin/restore.sh" --to "$WORK/restored" > "$WORK/restore.log" 2>&1
assert_true "restore.sh extracts the newest archive" $?
[ -f "$WORK/restored/source/docs/report.txt" ] && ok "the restored file exists" || bad "the restored file exists"

if [ -f "$WORK/restored/source/docs/report.txt" ]; then
    original="$(sha256sum < "$WORK/source/docs/report.txt")"
    restored="$(sha256sum < "$WORK/restored/source/docs/report.txt")"
    assert_equal "the restored file is byte identical" "$restored" "$original"

    original_blob="$(sha256sum < "$WORK/source/docs/blob.bin")"
    restored_blob="$(sha256sum < "$WORK/restored/source/docs/blob.bin")"
    assert_equal "the binary file survives the round trip" "$restored_blob" "$original_blob"
fi

printf '\nrestore refuses to overwrite\n'
"$ROOT/bin/restore.sh" --to "$WORK/restored" > "$WORK/restore2.log" 2>&1
assert_false "it stops when the target is not empty" $?

printf '\nrotation\n'
for i in 1 2 3 4 5; do
    stamp="2026010${i}-0300${i}0"
    touch "$WORK/primary/testjob-source-${stamp}-daily.tar.gz"
    touch "$WORK/primary/testjob-source-${stamp}-daily.tar.gz.sha256"
done
before="$(count_archives "$WORK/primary")"
"$ROOT/bin/backup.sh" > "$WORK/run2.log" 2>&1
after="$(find "$WORK/primary" -maxdepth 1 -name 'testjob-*-daily.tar.gz' | wc -l | tr -d ' ')"
assert_equal "daily archives are trimmed to KEEP_DAILY" "$after" "3"
[ "$before" -gt "$after" ] && ok "old archives were actually removed" || bad "old archives were actually removed"

oldest_left="$(find "$WORK/primary" -name 'testjob-*-daily.tar.gz' | sort | head -1)"
case "$oldest_left" in
    *2026010[45]*|*"$(date '+%Y%m%d')"*) ok "the newest archives are the ones kept" ;;
    *) bad "the newest archives are the ones kept (oldest left is $oldest_left)" ;;
esac

printf '\nconcurrency\n'
mkdir -p "$WORK/primary/.testjob.lock"
"$ROOT/bin/backup.sh" > "$WORK/run3.log" 2>&1
assert_false "a second run refuses to start while the lock is held" $?
rmdir "$WORK/primary/.testjob.lock"

printf '\nmissing source\n'
sed -i "s#^SOURCES=.*#SOURCES=\"$WORK/does-not-exist\"#" "$WORK/backup.conf"
"$ROOT/bin/backup.sh" > "$WORK/run4.log" 2>&1
assert_false "a missing source is reported as a failure" $?
grep -q 'does not exist' "$WORK/run4.log"
assert_true "the log says which source was missing" $?

printf '\nunmounted secondary\n'
sed -i "s#^SOURCES=.*#SOURCES=\"$WORK/source\"#" "$WORK/backup.conf"
sed -i "s#^SECONDARY_DIR=.*#SECONDARY_DIR=\"$WORK/not-mounted\"#" "$WORK/backup.conf"
"$ROOT/bin/backup.sh" > "$WORK/run5.log" 2>&1
assert_false "an unmounted second copy is not silently ignored" $?
grep -q 'not mounted' "$WORK/run5.log"
assert_true "the log explains why" $?

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
