#!/usr/bin/env bash
# No package updates or service mutations are made by these tests.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/fix-php2shell.sh"
TESTDIR=$(mktemp -d)
trap 'rm -rf -- "$TESTDIR"' EXIT
WORKDIR=$TESTDIR
TOTAL=0
expect() {
    local wanted=$1; shift
    local actual=0
    "$@" || actual=$?
    [[ $actual == "$wanted" ]] || { printf 'FAIL: expected=%s actual=%s: %s\n' "$wanted" "$actual" "$*"; exit 1; }
    TOTAL=$((TOTAL + 1))
}

expect 1 upstream_fixed 8.2.34
expect 0 upstream_fixed 8.2.35
expect 1 upstream_fixed 8.3.35
expect 0 upstream_fixed 8.3.36
expect 1 upstream_fixed 8.4.26
expect 0 upstream_fixed 8.4.27
expect 1 upstream_fixed 8.5.11
expect 0 upstream_fixed 8.5.12
expect 0 upstream_fixed 8.4.28-1ubuntu1
expect 0 upstream_fixed 2:8.4.27-1
expect 1 upstream_fixed 8.4.27RC1
expect 1 upstream_fixed 8.4.27~rc1
expect 1 upstream_fixed 8.6.0RC3
expect 1 upstream_fixed 8.1.99
expect 1 upstream_fixed garbage

# Real dpkg is used on Ubuntu. Git Bash has no dpkg; the tiny fallback only
# compares the numeric release revisions used below (not a dpkg replacement).
if ! command -v dpkg >/dev/null 2>&1; then
    dpkg() {
        [[ $1 == --compare-versions && $3 == ge ]] || return 1
        [[ $(printf '%s\n%s\n' "$2" "$4" | sort -V | tail -n 1) == "$2" ]]
    }
fi
OS_ID=ubuntu
OS_VERSION=22.04
expect 1 ubuntu_fixed php8.1 8.1.2-1ubuntu2.27
expect 0 ubuntu_fixed php8.1 8.1.2-1ubuntu2.28
expect 0 ubuntu_fixed php8.1 8.1.2-1ubuntu2.29
expect 1 ubuntu_fixed php8.1 8.1.2-1ubuntu2.28+ppa1
expect 1 ubuntu_fixed php8.1 8.1.2-1ubuntu2.28~rc1
OS_VERSION=24.04
expect 1 ubuntu_fixed php8.3 8.3.6-0ubuntu0.24.04.12
expect 0 ubuntu_fixed php8.3 8.3.6-0ubuntu0.24.04.13
expect 0 ubuntu_fixed php8.3 8.3.6-0ubuntu0.24.04.14
expect 1 ubuntu_fixed php8.3 8.3.6-0ubuntu0.24.04.13+ppa1
expect 1 ubuntu_fixed php8.1 8.1.2-1ubuntu2.28
OS_VERSION=26.04
expect 1 ubuntu_fixed php8.5 8.5.4-0ubuntu1.4
expect 0 ubuntu_fixed php8.5 8.5.4-0ubuntu1.5
OS_VERSION=26.10
expect 1 ubuntu_fixed php8.5 8.5.9-0ubuntu2
expect 0 ubuntu_fixed php8.5 8.5.9-0ubuntu2.1
OS_ID=debian
expect 1 ubuntu_fixed php8.5 8.5.9-0ubuntu2.1

OS_ID=ubuntu; OS_VERSION=24.04
printf 'installed\tphp8.3-fpm\t8.3.6-0ubuntu0.24.04.13\tphp8.3\t8.3.6-0ubuntu0.24.04.13\n' > "$WORKDIR/packages.tsv"
PENDING=0
verify_packages > /dev/null
expect 0 test "$PENDING" -eq 0
expect 0 test "$RUNTIMES" -eq 1
printf 'installed\tphp8.3-cli\t8.3.6-0ubuntu0.24.04.13\tphp8.3\t8.3.6-0ubuntu0.24.04.13\ninstalled\tphp8.3-fpm\t8.3.6-0ubuntu0.24.04.12\tphp8.3\t8.3.6-0ubuntu0.24.04.12\n' > "$WORKDIR/packages.tsv"
PENDING=0
verify_packages > /dev/null
expect 0 test "$PENDING" -eq 1
: > "$WORKDIR/packages.tsv"
PENDING=0
verify_packages > /dev/null
expect 0 test "$PENDING" -eq 1

# Simulate dpkg data to exercise inventory/ownership without invoking PHP.
dpkg-query() {
    case "$1" in
        -W) printf 'installed\tphp8.3-cli\t8.3.36-1\tphp8.3\t8.3.36-1\ninstalled\tphp8.3-fpm\t8.3.36-1\tphp8.3\t8.3.36-1\nconfig-files\tphp8.1-fpm\t8.1.2-1\tphp8.1\t8.1.2-1\ninstalled\tnginx\t1.24\tnginx\t1.24\n' ;;
        -S) [[ $2 == /usr/bin/php8.3 ]] && printf 'php8.3-cli: /usr/bin/php8.3\n' ;;
        *) return 1 ;;
    esac
}
inventory_packages > /dev/null
expect 0 test "${#PACKAGES[@]}" -eq 2
expect 0 managed_php_file /usr/bin/php8.3
expect 1 managed_php_file /usr/local/bin/php
expect 1 managed_php_file '/usr/bin/php*'

systemctl() {
    [[ $1 == list-units ]] || { printf 'Unexpected mutating systemctl in test\n' >&2; return 1; }
    printf 'php8.3-fpm.service loaded active running PHP\nnginx.service loaded active running nginx\n'
}
discover_services > /dev/null
expect 0 test "${#SERVICES[@]}" -eq 1
expect 0 test "${SERVICES[0]}" == php8.3-fpm.service
printf 'PASS: %s assertions\n' "$TOTAL"
