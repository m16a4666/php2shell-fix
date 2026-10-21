#!/usr/bin/env bash
# Standard BaoTa /www/server/php/82 installation, Ubuntu only.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077

BT_ROOT=/www/server/php/82
BT_INIT=/etc/init.d/php-fpm-82
BT_FPM_REAL=$BT_ROOT/sbin/php-fpm
BT_VENDOR_URL=https://download.bt.cn/install/0/php.sh
# Reviewed 2026-10-21: update preserves php.ini/FPM config, uses PHP 8.2.35.
BT_VENDOR_SHA=63135389a18588fb6f096e2584e6f8e49797247f1e14c8acc56ea0fd924db02f
BT_WORK=''
BT_WAS_ACTIVE=0
BT_APPLY=0

bt_say() { printf '%s\n' "$*"; }
bt_die() { bt_say "[未完成] $*" >&2; exit 1; }
bt_usage() {
    bt_say '用法：sudo bash fix-bt-php82.sh --apply（备份并更新宝塔 PHP 8.2）'
    bt_say '      sudo bash fix-bt-php82.sh --check（默认，仅检查文件版本）'
}
bt_parse_version() {
    local line
    while IFS= read -r line; do
        if [[ $line =~ ^PHP\ ([0-9]+\.[0-9]+\.[0-9]+[^\ ]*) ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    done
    return 1
}
bt_fixed() {
    [[ $1 =~ ^8\.2\.([0-9]+)$ ]] || return 1
    (( 10#${BASH_REMATCH[1]} >= 35 ))
}
bt_vendor_version() {
    local line
    while IFS= read -r line; do
        if [[ $line =~ ^php_82=[\"\'](8\.2\.[0-9]+)[\"\']$ ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    done < "$1"
    return 1
}
bt_version() {
    local output
    output=$(timeout 15 "$1" -n -v) || return 1
    bt_parse_version <<< "$output"
}
bt_pids() {
    local proc exe
    for proc in /proc/[0-9]*; do
        exe=$(readlink "$proc/exe" 2>/dev/null) || continue
        if [[ $exe == "$BT_FPM_REAL" || $exe == "$BT_FPM_REAL (deleted)" ]]; then
            printf '%s\n' "${proc##*/}"
        fi
    done
    return 0
}
bt_modules() {
    local target=$1 errors=$2
    timeout 20 "$BT_ROOT/bin/php" -m > "$target.raw" 2> "$errors" || return 1
    if [[ -s $errors ]]; then cat "$errors" >&2; return 1; fi
    awk 'NF && $0 !~ /^\[/' "$target.raw" | sort -u > "$target"
}
bt_exit() {
    local rc=$1
    trap - EXIT
    if (( rc != 0 && BT_APPLY && BT_WAS_ACTIVE )) && [[ -n $BT_WORK ]]; then
        # A vendor failure may leave FPM stopped. Try starting the installed
        # runtime only if its config still validates; do not overlay a backup.
        local pids
        pids=$(bt_pids)
        if [[ -z $pids ]] && "$BT_ROOT/sbin/php-fpm" -t >> "$BT_WORK/run.log" 2>&1; then
            bt_say '[恢复服务尝试] 更新未完成，尝试启动当前可用 FPM；这不代表漏洞已修复。'
            "$BT_INIT" start || true
        fi
    fi
    if (( rc != 0 )); then bt_say "[未完成] 请查看日志/备份：${BT_WORK:-尚未创建}" >&2; fi
    exit "$rc"
}

bt_main() {
    (($# <= 1)) || { bt_usage; return 1; }
    case "${1:---check}" in
        --apply) BT_APPLY=1 ;; --check) BT_APPLY=0 ;;
        --help|-h) bt_usage; return 0 ;; *) bt_usage; return 1 ;;
    esac
    [[ $(uname -s) == Linux && $EUID -eq 0 ]] || bt_die '请在目标 Ubuntu 上以 root/sudo 执行。'
    [[ -r /etc/os-release ]] || bt_die '无法确定系统。'
    # shellcheck source=/dev/null
    . /etc/os-release
    [[ ${ID:-} == ubuntu ]] || bt_die '本入口只支持 Ubuntu 标准宝塔 PHP 8.2。'
    [[ ! -e /.dockerenv && ! -e /run/.containerenv ]] || bt_die '请在宿主机操作。'
    [[ -f /var/bt_setupPath.conf && $(cat /var/bt_setupPath.conf) == /www &&
        -f /www/server/panel/install/public.sh ]] || bt_die '不是已识别的标准宝塔安装，停止。'
    [[ -x $BT_ROOT/bin/php && -x $BT_ROOT/sbin/php-fpm && -x $BT_INIT ]] || bt_die '缺少 PHP 8.2 二进制或标准启动脚本。'
    [[ ! -L $BT_ROOT ]] || bt_die 'PHP 8.2 目录是符号链接，需单独确定备份和更新目标。'
    [[ ! -L $BT_ROOT/sbin/php-fpm && ! -L $BT_ROOT/bin/php ]] || bt_die 'PHP 二进制是符号链接，需单独确定更新目标。'
    BT_FPM_REAL=$(readlink -f "$BT_ROOT/sbin/php-fpm") || bt_die '无法确定 FPM 实际路径。'
    local cmd cli fpm vendor pids path size free_log free_php old_pid old_exe missing
    for cmd in curl sha256sum tar flock timeout awk sort comm du df tee; do
        command -v "$cmd" >/dev/null || bt_die "缺少依赖：$cmd"
    done
    exec 9>/run/lock/php2shell-fix.lock
    flock -n 9 || bt_die '已有修复或检查任务正在运行。'
    BT_WORK=$(mktemp -d /var/log/php2shell-bt82.XXXXXXXX)
    exec > >(tee -a "$BT_WORK/run.log") 2>&1
    trap 'bt_exit "$?"' EXIT
    bt_say "[记录] $BT_WORK（仅 root 可读）"
    cli=$(bt_version "$BT_ROOT/bin/php") || bt_die '读取 CLI 版本失败。'
    fpm=$(bt_version "$BT_ROOT/sbin/php-fpm") || bt_die '读取 FPM 版本失败。'
    bt_say "[当前] $BT_ROOT | CLI=$cli | FPM=$fpm"
    [[ $cli =~ ^8\.2\. && $fpm =~ ^8\.2\. ]] || bt_die '目录内容不是 PHP 8.2，拒绝跨分支升级。'
    pids=$(bt_pids)
    [[ -z $pids ]] || BT_WAS_ACTIVE=1
    printf '%s\n' "$pids" > "$BT_WORK/pids-before.txt"
    if (( ! BT_APPLY )); then
        if bt_fixed "$cli" && bt_fixed "$fpm"; then
            bt_say '[文件版本通过] PHP 8.2.35 或更高；本检查未证明已有 worker 已重新启动。'
        else
            bt_say '[待更新] CLI/FPM 未全部达到 8.2.35。'
            return 2
        fi
        return 0
    fi
    "$BT_ROOT/sbin/php-fpm" -t || bt_die '原有 FPM 配置无效，尚未开始更新。'
    bt_modules "$BT_WORK/modules-before.txt" "$BT_WORK/modules-before.err" || bt_die '原有 CLI 扩展加载异常，尚未开始更新。'
    if ! bt_fixed "$cli" || ! bt_fixed "$fpm"; then
        curl -fL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 90 \
            "$BT_VENDOR_URL" -o "$BT_WORK/php-vendor.sh"
        printf '%s  %s\n' "$BT_VENDOR_SHA" "$BT_WORK/php-vendor.sh" | sha256sum -c - ||
            bt_die '宝塔官方脚本内容已变更；请重新核查，未执行更新。'
        bash -n "$BT_WORK/php-vendor.sh"
        vendor=$(bt_vendor_version "$BT_WORK/php-vendor.sh") || bt_die '无法确认官方目标版本。'
        bt_fixed "$vendor" || bt_die "官方目标 $vendor 未达到修复版本，未执行。"
        size=$(du -sk --exclude=src "$BT_ROOT" | awk '{print $1}')
        free_log=$(df -Pk "$BT_WORK" | awk 'END {print $4}')
        free_php=$(df -Pk "$BT_ROOT" | awk 'END {print $4}')
        [[ $size =~ ^[0-9]+$ && $free_log =~ ^[0-9]+$ && $free_php =~ ^[0-9]+$ ]] || bt_die '无法确认磁盘空间。'
        (( free_log > size + 524288 && free_php > size + 2097152 )) ||
            bt_die '备份/编译磁盘空间不足：请预留运行时大小之外至少 2 GiB。'
        bt_say '[备份] 保存现有 PHP 8.2 目录（含配置与扩展，排除 src 构建目录）。'
        tar -C /www/server/php --exclude=82/src -czf "$BT_WORK/php82-before.tar.gz" -- 82
        # Retain exact configuration evidence, without displaying secret values.
        for path in "$BT_ROOT/etc/php.ini" "$BT_ROOT/etc/php-fpm.conf"; do
            [[ ! -f $path ]] || sha256sum "$path" >> "$BT_WORK/config-before.sha256"
        done
        bt_say "[更新] 调用宝塔官方编译脚本 update 8.2，目标 $vendor；可能耗时较长，安装阶段网站会短暂中断。"
        (cd "$BT_WORK" && bash ./php-vendor.sh update 8.2) || bt_die '官方更新脚本执行失败。'
    fi
    cli=$(bt_version "$BT_ROOT/bin/php") || bt_die '更新后 CLI 无法运行。'
    fpm=$(bt_version "$BT_ROOT/sbin/php-fpm") || bt_die '更新后 FPM 无法运行。'
    if ! bt_fixed "$cli" || ! bt_fixed "$fpm"; then
        bt_die "文件补丁未通过：CLI=$cli FPM=$fpm。"
    fi
    if [[ -f $BT_WORK/config-before.sha256 ]]; then
        sha256sum -c "$BT_WORK/config-before.sha256" || bt_die 'php.ini/FPM 主配置发生变化，请核对备份。'
    fi
    bt_modules "$BT_WORK/modules-after.txt" "$BT_WORK/modules-after.err" || bt_die '更新后 CLI 扩展加载异常。'
    missing=$(comm -23 "$BT_WORK/modules-before.txt" "$BT_WORK/modules-after.txt")
    [[ -z $missing ]] || bt_die "更新后缺少原有扩展：$missing"
    "$BT_ROOT/sbin/php-fpm" -t || bt_die '更新后 FPM 配置无效。'
    if (( BT_WAS_ACTIVE )); then
        "$BT_INIT" restart || bt_die 'FPM 重启失败。'
        pids=$(bt_pids)
        [[ -n $pids ]] || bt_die '重启后未发现 PHP 8.2 FPM 进程。'
        while IFS= read -r old_pid; do
            [[ -n $old_pid ]] || continue
            old_exe=$(readlink "/proc/$old_pid/exe" 2>/dev/null) || continue
            [[ $old_exe != "$BT_FPM_REAL" && $old_exe != "$BT_FPM_REAL (deleted)" ]] ||
                bt_die "原有 FPM PID $old_pid 仍存活，请核验启动脚本。"
        done < "$BT_WORK/pids-before.txt"
    else
        # The vendor update starts FPM even when it was originally stopped.
        "$BT_INIT" stop || bt_die '无法恢复原来停止的 FPM 状态。'
        [[ -z $(bt_pids) ]] || bt_die '原来停止的 FPM 仍在运行。'
    fi
    bt_say "[通过] 宝塔 PHP 8.2 文件版本：CLI=$cli FPM=$fpm；原有活动 FPM 已替换，原有扩展列表通过。"
    bt_say "备份与日志：$BT_WORK。请检查实际网站访问、登录和上传。其他 PHP 分支/容器需单独核验。"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    bt_main "$@"
fi
