#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/fix-bt-php82.sh"
TESTDIR=$(mktemp -d)
trap 'rm -rf -- "$TESTDIR"' EXIT
TOTAL=0
expect() {
    local wanted=$1; shift
    local actual=0
    "$@" || actual=$?
    [[ $actual == "$wanted" ]] || { printf 'FAIL: %s\n' "$*"; exit 1; }
    TOTAL=$((TOTAL + 1))
}
expect 1 bt_fixed 8.2.34
expect 0 bt_fixed 8.2.35
expect 0 bt_fixed 8.2.36
expect 1 bt_fixed 8.3.36
expect 1 bt_fixed 8.2.35RC1
expect 1 bt_fixed 8.2.35~rc1
expect 1 bt_fixed 8.2.35-unknown
expect 1 bt_fixed garbage
expect 0 test "$(bt_parse_version <<< 'PHP 8.2.34 (cli) (built: Oct 21 2026)')" == 8.2.34
expect 0 test "$(bt_parse_version <<< 'PHP 8.2.35 (fpm-fcgi) (built: Oct 21 2026)')" == 8.2.35
expect 0 test "$(bt_parse_version <<< $'Startup diagnostic\nPHP 8.2.35 (cli)')" == 8.2.35
expect 1 bt_parse_version <<< 'not a version'
printf "php_82='8.2.35'\nphp_83='8.3.36'\n" > "$TESTDIR/vendor.sh"
expect 0 test "$(bt_vendor_version "$TESTDIR/vendor.sh")" == 8.2.35
printf 'php_82="8.2.36"\n' > "$TESTDIR/vendor.sh"
expect 0 test "$(bt_vendor_version "$TESTDIR/vendor.sh")" == 8.2.36
printf "php_82='8.2.35RC1'\n" > "$TESTDIR/vendor.sh"
expect 1 bt_vendor_version "$TESTDIR/vendor.sh"
# shellcheck disable=SC2016
printf 'php_82=$(touch injected)\n' > "$TESTDIR/vendor.sh"
expect 1 bt_vendor_version "$TESTDIR/vendor.sh"
expect 0 test ! -e injected
printf 'PASS: %s BaoTa assertions (vendor updater not executed)\n' "$TOTAL"
