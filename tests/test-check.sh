#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/check-php2shell.sh"
TESTDIR=$(mktemp -d)
trap 'rm -rf -- "$TESTDIR"' EXIT
TOTAL=0
expect() {
    local wanted=$1; shift
    local actual=0
    "$@" || actual=$?
    [[ $actual == "$wanted" ]] || { printf 'FAIL expected=%s actual=%s: %s\n' "$wanted" "$actual" "$*"; exit 1; }
    TOTAL=$((TOTAL + 1))
}
expect 2 p2_grade_version 8.2.34
expect 0 p2_grade_version 8.2.35
expect 0 p2_grade_version 8.2.36
expect 2 p2_grade_version 8.3.35
expect 0 p2_grade_version 8.3.36
expect 2 p2_grade_version 8.4.26
expect 0 p2_grade_version 8.4.27
expect 2 p2_grade_version 8.5.11
expect 0 p2_grade_version 8.5.12
expect 2 p2_grade_version 5.6.40
expect 2 p2_grade_version 7.4.33
expect 2 p2_grade_version 8.1.34
expect 3 p2_grade_version 8.2.35RC1
expect 3 p2_grade_version 8.2.35-custom
expect 3 p2_grade_version 8.6.0
expect 3 p2_grade_version garbage
expect 0 test "$(p2_parse_version <<< 'PHP 8.2.35 (fpm-fcgi) (built: today)')" == 8.2.35
expect 1 p2_parse_version <<< 'Unknown program'

expect 0 p2_live_relation 1:200 1:200 100 101
expect 3 p2_live_relation 1:200 1:201 100 101
expect 3 p2_live_relation 1:200 1:200 100 99
expect 3 p2_live_relation 1:200 1:200 100 100
expect 3 p2_live_relation 1:200 1:200 unknown 101
expect 3 p2_live_relation 1:200 1:200 100 unknown

# /proc stat field 22 = 250 ticks. Embedded parentheses in comm are valid.
printf '123 (php-fpm (pool)) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 250 22\n' > "$TESTDIR/stat"
expect 0 test "$(p2_start_epoch "$TESTDIR" 1000 100)" == 1002
expect 1 p2_start_epoch "$TESTDIR" 1000 0

# These tests must never claim safety when only a file/CLI has been checked.
P2_RISK=0; P2_UNKNOWN=0; P2_FILES=2; P2_LIVE=5; P2_WEB=5
expect 0 p2_result
P2_RISK=1; P2_UNKNOWN=0; P2_FILES=2; P2_LIVE=5
expect 2 p2_result
P2_RISK=0; P2_UNKNOWN=1; P2_FILES=2; P2_LIVE=5
expect 3 p2_result
P2_RISK=0; P2_UNKNOWN=0; P2_FILES=2; P2_LIVE=0; P2_WEB=0
expect 3 p2_result
P2_RISK=0; P2_UNKNOWN=0; P2_FILES=2; P2_LIVE=5; P2_WEB=0
expect 3 p2_result
P2_RISK=0; P2_UNKNOWN=0; P2_FILES=0; P2_LIVE=0; P2_WEB=0
expect 3 p2_result

# Exercise per-file classification using a stub for PHP execution only.
printf '#!/bin/sh\nexit 0\n' > "$TESTDIR/php"
chmod +x "$TESTDIR/php"
p2_version() { printf '%s\n' "$FIXTURE_VERSION"; }
P2_RISK=0; P2_UNKNOWN=0; P2_FILES=0
FIXTURE_VERSION=8.2.35
p2_check_file "$TESTDIR/php" 82
expect 0 test "$P2_RISK" -eq 0
expect 0 test "$P2_UNKNOWN" -eq 0
expect 0 test "$P2_FILES" -eq 1
# Duplicate aliases should not add an installation.
p2_check_file "$TESTDIR/php" 82
expect 0 test "$P2_FILES" -eq 1
printf '#!/bin/sh\nexit 0\n' > "$TESTDIR/php-fpm"
chmod +x "$TESTDIR/php-fpm"
FIXTURE_VERSION=8.2.34
p2_check_file "$TESTDIR/php-fpm" 82
expect 0 test "$P2_RISK" -eq 1
expect 0 test "$P2_FILES" -eq 2
P2_LIVE=10
expect 2 p2_result

# A source directory or a mismatched binary cannot produce a pass.
printf '#!/bin/sh\nexit 0\n' > "$TESTDIR/wrong"
chmod +x "$TESTDIR/wrong"
P2_UNKNOWN=0
FIXTURE_VERSION=8.3.36
p2_check_file "$TESTDIR/wrong" 82
expect 0 test "$P2_UNKNOWN" -eq 1

# A fixture proc tree verifies process scanning, including deleted old workers.
P2_STATUS=(); P2_PRINT=(); P2_ID=(); P2_CHANGED=(); P2_COUNT=(); P2_LIVE_BAD=(); P2_FINGER=(); P2_EXTRA=()
P2_RISK=0; P2_UNKNOWN=0; P2_FILES=0; P2_LIVE=0
FIXTURE_VERSION=8.2.35
mkdir -p "$TESTDIR/82/sbin" "$TESTDIR/proc/100"
printf '#!/bin/sh\nexit 0\n' > "$TESTDIR/82/sbin/php-fpm"
chmod +x "$TESTDIR/82/sbin/php-fpm"
p2_check_file "$TESTDIR/82/sbin/php-fpm" 82
FPM_REAL=$(command readlink -f "$TESTDIR/82/sbin/php-fpm")
# /proc exe links are special kernel objects. Mock their readlink/stat behavior
# so this fixture also works on Git Bash without Windows symlink privileges.
printf '%s\n' "$FPM_REAL" > "$TESTDIR/proc/100/exe"
readlink() {
    if [[ ${!#} == "$TESTDIR/proc/100/exe" ]]; then cat "$TESTDIR/proc/100/exe";
    else command readlink "$@"; fi
}
stat() {
    if [[ ${!#} == "$TESTDIR/proc/100/exe" ]]; then
        command stat "${@:1:$#-1}" "$(cat "$TESTDIR/proc/100/exe")"
    else command stat "$@"; fi
}
printf 'btime %s\n' "$(( P2_CHANGED[$FPM_REAL] + 1 ))" > "$TESTDIR/proc/stat"
cp "$TESTDIR/stat" "$TESTDIR/proc/100/stat"
: > "$TESTDIR/proc/100/maps"
p2_scan_processes "$TESTDIR/proc"
expect 0 test "$P2_LIVE" -eq 1
expect 0 test "$P2_UNKNOWN" -eq 0
expect 0 p2_result

# Simulate a deleted inode still held by a worker. Never pass based on CLI alone.
cp "$FPM_REAL" "$FPM_REAL (deleted)"
printf '%s\n' "$FPM_REAL (deleted)" > "$TESTDIR/proc/100/exe"
P2_LIVE=0; P2_WEB=0; P2_COUNT[$FPM_REAL]=0
p2_scan_processes "$TESTDIR/proc"
expect 0 test "$P2_UNKNOWN" -eq 1
expect 3 p2_result
printf 'PASS: %s verifier assertions\n' "$TOTAL"
