#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $(uname -s) != Linux ]] || ! command -v flock >/dev/null; then
    printf 'SKIP: lock inheritance regression requires Linux flock and /proc\n'
    exit 0
fi
source "$ROOT/fix-bt-php82.sh"
TESTDIR=$(mktemp -d)
trap 'rm -rf -- "$TESTDIR"' EXIT
cat > "$TESTDIR/fake-init" <<'SERVICE'
#!/usr/bin/env bash
# No real service: fail if the updater leaked its lock descriptor.
if [[ -e /proc/$$/fd/9 ]]; then exit 42; fi
exit 0
SERVICE
chmod +x "$TESTDIR/fake-init"
BT_INIT=$TESTDIR/fake-init
exec 9>"$TESTDIR/lock"
flock -n 9
bt_service restart
bt_service start
bt_service stop
if flock -n "$TESTDIR/lock" true; then
    printf 'FAIL: service invocation released parent lock prematurely\n' >&2
    exit 1
fi
bt_release_lock
flock -n "$TESTDIR/lock" true
# Explicit unlock must also release a legacy duplicated open description.
exec 9>"$TESTDIR/lock"
flock -n 9
exec 8>&9
bt_release_lock
flock -n "$TESTDIR/lock" true
exec 8>&-
printf 'PASS: service FD isolation, parent lock lifetime and explicit unlock\n'
