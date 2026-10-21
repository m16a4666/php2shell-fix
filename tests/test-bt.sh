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
expect 0 bt_supported_os ubuntu 24.04
expect 0 bt_supported_os debian 11
expect 0 bt_supported_os debian 12
expect 0 bt_supported_os debian 13
expect 1 bt_supported_os debian 10
expect 1 bt_supported_os rocky 9
printf 'PHP Warning:  Module "zip" is already loaded in Unknown on line 0\n' > "$TESTDIR/diagnostics"
expect 0 bt_diagnostics_ok "$TESTDIR/diagnostics"
printf 'Warning: Module "zip" is already loaded in Unknown on line 0\n' > "$TESTDIR/diagnostics"
expect 0 bt_diagnostics_ok "$TESTDIR/diagnostics"
printf 'PHP Warning:  Module "zip" is already loaded in Unknown on line 0\nPHP Warning: Unable to load dynamic library redis.so\n' > "$TESTDIR/diagnostics"
expect 1 bt_diagnostics_ok "$TESTDIR/diagnostics"
printf 'PHP Fatal error: failed startup\n' > "$TESTDIR/diagnostics"
expect 1 bt_diagnostics_ok "$TESTDIR/diagnostics"
: > "$TESTDIR/diagnostics"
expect 0 bt_diagnostics_ok "$TESTDIR/diagnostics"

# Stub only PHP execution; exercise actual parsing of both output streams.
timeout() {
    case "$PHP_FIXTURE" in
        duplicate)
            printf '[PHP Modules]\nCore\nzip\n[Zend Modules]\n'
            printf 'PHP Warning:  Module "zip" is already loaded in Unknown on line 0\n' >&2 ;;
        stdout_duplicate)
            printf 'Warning: Module "zip" is already loaded in Unknown on line 0\n[PHP Modules]\nCore\nzip\n[Zend Modules]\n' ;;
        zip_absent)
            printf '[PHP Modules]\nCore\n[Zend Modules]\n'
            printf 'PHP Warning:  Module "zip" is already loaded in Unknown on line 0\n' >&2 ;;
        broken)
            printf '[PHP Modules]\nCore\nzip\n'
            printf 'PHP Warning: Unable to load dynamic library redis.so\n' >&2 ;;
        stdout_broken) printf 'Warning: Unable to load dynamic library redis.so\n[PHP Modules]\nCore\nzip\n' ;;
        failed) return 42 ;;
        clean) printf '[PHP Modules]\nCore\nzip\n[Zend Modules]\n' ;;
        *) return 1 ;;
    esac
}
PHP_FIXTURE=duplicate
expect 0 bt_modules "$TESTDIR/modules" "$TESTDIR/errors"
expect 0 test "$(cat "$TESTDIR/modules")" == $'Core\nzip'
PHP_FIXTURE=stdout_duplicate
expect 0 bt_modules "$TESTDIR/modules" "$TESTDIR/errors"
expect 0 test "$(cat "$TESTDIR/modules")" == $'Core\nzip'
PHP_FIXTURE=zip_absent
expect 1 bt_modules "$TESTDIR/modules" "$TESTDIR/errors"
PHP_FIXTURE=broken
expect 1 bt_modules "$TESTDIR/modules" "$TESTDIR/errors"
PHP_FIXTURE=stdout_broken
expect 1 bt_modules "$TESTDIR/modules" "$TESTDIR/errors"
PHP_FIXTURE=failed
expect 1 bt_modules "$TESTDIR/modules" "$TESTDIR/errors"
PHP_FIXTURE=clean
expect 0 bt_modules "$TESTDIR/modules" "$TESTDIR/errors"
printf 'PASS: %s BaoTa assertions (vendor updater not executed)\n' "$TOTAL"
