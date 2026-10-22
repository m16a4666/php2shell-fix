#!/usr/bin/env bash
# Read-only verification of standard BaoTa PHP installations and host processes.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077

P2_RISK=0
P2_UNKNOWN=0
P2_FILES=0
P2_LIVE=0
P2_WEB=0
P2_SITE=''
P2_DOCROOT=''
P2_PROBE_FILE=''
declare -A P2_STATUS=() P2_PRINT=() P2_ID=() P2_CHANGED=() P2_COUNT=() P2_LIVE_BAD=() P2_FINGER=()
declare -A P2_EXTRA=()

p2_say() { printf '%s\n' "$*"; }
p2_unknown() { P2_UNKNOWN=1; p2_say "[无法确认] $*"; }
p2_risk() { P2_RISK=1; p2_say "[未达修复基线] $*"; }
p2_usage() {
    p2_say '用法：sudo bash check-php2shell.sh'
    p2_say '      sudo bash check-php2shell.sh --site example.com --docroot /www/wwwroot/example.com'
    p2_say '只读检查 /www/server/php/* 的 CLI/FPM 文件版本和宿主机活动 PHP 进程。'
    p2_say '不会安装、修改配置、重启服务或发送网络利用请求。'
    p2_say '--site 模式会在指定运行目录临时创建随机 PHP 探针，仅允许本机+随机令牌访问，结束时删除。'
    p2_say '退出码：0=识别范围通过；1=执行失败；2=版本未达修复基线；3=无法确认。'
}
p2_check_lock() {
    local lock_path=$1
    [[ -e $lock_path ]] || return 0
    exec 9<"$lock_path"
    if ! flock -sn 9; then
        exec 9<&-
        p2_unknown '修复锁被占用：可能正在更新，也可能是旧版服务继承了锁。继续读取版本与进程快照，不删除锁或停止服务。'
        p2_say '[提示] 本次仍会输出各项结果，但占锁未排除前不会报告全部通过。'
    fi
}
p2_valid_site() {
    [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $1 != *..* ]]
}
p2_cleanup_probe() {
    if [[ -n $P2_PROBE_FILE ]]; then
        if rm -f -- "$P2_PROBE_FILE"; then
            P2_PROBE_FILE=''
        else
            p2_unknown "无法删除临时探针，请手动删除：$P2_PROBE_FILE"
            return 1
        fi
    fi
}
p2_parse_site() {
    local token=$1 body=$2 i version sapi
    local -a lines
    mapfile -t lines <<< "$body"
    for (( i=0; i<${#lines[@]}; i++ )); do
        [[ ${lines[$i]%$'\r'} == "P2S:$token" ]] || continue
        version=${lines[$((i+1))]:-}; version=${version%$'\r'}
        sapi=${lines[$((i+2))]:-}; sapi=${sapi%$'\r'}
        [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*$ && $sapi =~ ^[a-z][a-z0-9_-]+$ ]] || return 1
        printf '%s|%s\n' "$version" "$sapi"
        return 0
    done
    return 1
}
p2_check_site() {
    local site=$1 root=$2 token name scheme port body result version sapi grade=0
    p2_valid_site "$site" || { p2_unknown '域名格式无效（不接受协议、路径或端口）。'; return; }
    root=$(readlink -e -- "$root") || { p2_unknown '网站实际运行目录不存在。'; return; }
    [[ -d $root && $root != / ]] || { p2_unknown '必须指定网站实际运行目录，不能使用 /。'; return; }
    token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    [[ $token =~ ^[0-9a-f]{32}$ ]] || { p2_unknown '无法生成站点检查令牌。'; return; }
    P2_PROBE_FILE=$(mktemp --tmpdir="$root" p2s-verify.XXXXXXXX.php) || { p2_unknown '无法创建临时站点探针。'; return; }
    name=${P2_PROBE_FILE##*/}
    # A random filename alone is insufficient: require loopback and a secret header.
    cat > "$P2_PROBE_FILE" <<PHP
<?php
if (!in_array(\$_SERVER['REMOTE_ADDR'] ?? '', ['127.0.0.1', '::1'], true)
    || !hash_equals('$token', \$_SERVER['HTTP_X_P2S_VERIFY'] ?? '')) {
    http_response_code(404); exit;
}
header('Content-Type: text/plain');
header('Cache-Control: no-store, private');
echo 'P2S:$token', "\\n", PHP_VERSION, "\\n", PHP_SAPI, "\\n";
PHP
    chmod 0644 "$P2_PROBE_FILE"
    p2_say "[站点检查] $site → 本机 127.0.0.1，运行目录 $root（临时探针将删除）"
    result=''
    for scheme in https http; do
        if [[ $scheme == https ]]; then port=443; else port=80; fi
        # No redirects, proxy environment, insecure TLS, or remote target requests.
        if body=$(curl -fsS --noproxy '*' --proto '=http,https' --connect-timeout 3 --max-time 10 --max-filesize 65536 \
            --resolve "$site:$port:127.0.0.1" -H "X-P2S-Verify: $token" -H 'Cache-Control: no-cache' \
            "$scheme://$site/$name" 9>&- 2>/dev/null); then
            result=$(p2_parse_site "$token" "$body") || result=''
            [[ -z $result ]] || break
        fi
    done
    p2_cleanup_probe || return 0
    [[ -n $result ]] || { p2_unknown "$site：没有取得带匹配令牌的 PHP 响应；请确认实际运行目录、站点绑定、TLS 和本机 80/443 监听。"; return; }
    version=${result%%|*}; sapi=${result#*|}
    p2_grade_version "$version" || grade=$?
    case "$grade" in
        0) p2_say "[站点通过] $site 本次本机源站请求实际 PHP=$version，SAPI=$sapi；探针已删除。" ;;
        2) p2_risk "$site 实际请求返回 PHP=$version，SAPI=$sapi；探针已删除。" ;;
        *) p2_unknown "$site 实际 PHP=$version，SAPI=$sapi，不属于已核实正式修复版本；探针已删除。" ;;
    esac
}
p2_parse_version() {
    local line
    while IFS= read -r line; do
        if [[ $line =~ ^PHP\ ([0-9]+\.[0-9]+\.[0-9]+[^\ ]*) ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    done
    return 1
}
# 0 = known fixed release, 2 = below upstream baseline, 3 = unknown build.
# BaoTa custom backports with an older version need separate vendor evidence.
p2_grade_version() {
    local major minor patch floor
    [[ $1 =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 3
    major=${BASH_REMATCH[1]}; minor=${BASH_REMATCH[2]}; patch=${BASH_REMATCH[3]}
    case "$major.$minor" in
        8.2) floor=35 ;; 8.3) floor=36 ;; 8.4) floor=27 ;; 8.5) floor=12 ;;
        5.*|7.*|8.0|8.1) return 2 ;;
        *) return 3 ;;
    esac
    (( 10#$patch >= floor )) && return 0
    return 2
}
p2_version() {
    local output
    output=$(timeout 15 "$1" -n -v 2>&1) || return 1
    p2_parse_version <<< "$output"
}
p2_fingerprint() { stat -Lc '%d:%i:%s:%Y:%Z' -- "$1"; }
p2_live_relation() {
    # Matching inode alone is insufficient if the file changed after startup.
    local disk_id=$1 live_id=$2 changed=$3 started=$4
    [[ $disk_id == "$live_id" && $changed =~ ^[0-9]+$ && $started =~ ^[0-9]+$ ]] || return 3
    (( started > changed )) || return 3
}
p2_start_epoch() {
    local proc=$1 boot=$2 hz=$3 line rest
    local -a fields
    line=$(cat "$proc/stat" 2>/dev/null) || return 1
    rest=${line##*) }
    read -r -a fields <<< "$rest"
    [[ ${fields[19]:-} =~ ^[0-9]+$ && $boot =~ ^[0-9]+$ && $hz =~ ^[0-9]+$ && $hz -gt 0 ]] || return 1
    printf '%s\n' "$(( boot + fields[19] / hz ))"
}
p2_check_file() {
    local path=$1 branch=$2 real before after version grade=0 expected
    real=$(readlink -f -- "$path") || { p2_unknown "无法解析 $path"; return; }
    [[ ! ${P2_STATUS[$real]+present} ]] || return 0
    P2_FILES=$((P2_FILES + 1))
    P2_STATUS[$real]=3
    P2_PRINT[$real]=$path
    [[ -x $real && -f $real ]] || { p2_unknown "不可执行：$path"; return; }
    before=$(p2_fingerprint "$real") || { p2_unknown "无法读取文件状态：$path"; return; }
    version=$(p2_version "$real") || { p2_unknown "无法读取版本：$path"; return; }
    after=$(p2_fingerprint "$real") || { p2_unknown "检查时文件消失：$path"; return; }
    [[ $before == "$after" ]] || { p2_unknown "读取版本期间文件发生变化：$path"; return; }
    if [[ $version =~ ^([0-9]+)\.([0-9]+)\. ]]; then
        expected=${BASH_REMATCH[1]}${BASH_REMATCH[2]}
        [[ $expected == "$branch" ]] || { p2_unknown "$path 的版本 $version 与目录 $branch 不一致"; return; }
    fi
    p2_grade_version "$version" || grade=$?
    P2_STATUS[$real]=$grade
    P2_ID[$real]=$(stat -Lc '%d:%i' -- "$real")
    P2_CHANGED[$real]=$(stat -Lc '%Z' -- "$real")
    P2_FINGER[$real]=$after
    case "$grade" in
        0) p2_say "[文件通过] $path → PHP $version" ;;
        2) p2_risk "$path → PHP $version；若厂商有回补但未改版本号，需要另行提供补丁证据。" ;;
        *) p2_unknown "$path → $version；不是已知正式修复版本。" ;;
    esac
    P2_COUNT[$real]=0
    P2_LIVE_BAD[$real]=0
}
p2_scan_processes() {
    local proc_root=${1:-/proc} boot hz proc exe clean name real live_id started module
    boot=$(awk '$1 == "btime" {print $2; exit}' "$proc_root/stat")
    hz=$(getconf CLK_TCK)
    for proc in "$proc_root"/[0-9]*; do
        exe=$(readlink "$proc/exe" 2>/dev/null) || continue
        clean=${exe% (deleted)}
        name=${clean##*/}
        if [[ $name =~ ^(php([0-9.]+)?|php-fpm([0-9.]+)?|php-cgi([0-9.]+)?|lsphp.*|frankenphp.*|caddy)$ ]]; then
            real=$clean
            if [[ ${P2_STATUS[$real]+present} ]]; then
                live_id=$(stat -Lc '%d:%i' -- "$proc/exe" 2>/dev/null) || continue
                started=$(p2_start_epoch "$proc" "$boot" "$hz") || {
                    [[ -d $proc ]] || continue
                    started=unknown
                }
                P2_COUNT[$real]=$(( ${P2_COUNT[$real]:-0} + 1 ))
                if [[ $exe == *' (deleted)' ]] || ! p2_live_relation "${P2_ID[$real]:-unknown}" "$live_id" "${P2_CHANGED[$real]:-unknown}" "$started"; then
                    P2_LIVE_BAD[$real]=$(( ${P2_LIVE_BAD[$real]:-0} + 1 ))
                elif [[ ${P2_STATUS[$real]} == 0 ]]; then
                    P2_LIVE=$((P2_LIVE + 1))
                    if [[ ${P2_PRINT[$real]} == */sbin/php-fpm ]]; then
                        P2_WEB=$((P2_WEB + 1))
                    fi
                fi
            else
                P2_EXTRA["活动运行时：$exe"]=$(( ${P2_EXTRA["活动运行时：$exe"]:-0} + 1 ))
            fi
        fi
        [[ -r $proc/maps ]] || { [[ ! -d $proc ]] || p2_unknown "无法读取 PID ${proc##*/} 的内存映射"; continue; }
        while IFS= read -r module; do
            [[ -n $module ]] || continue
            P2_EXTRA["加载的 PHP 模块：$module"]=$(( ${P2_EXTRA["加载的 PHP 模块：$module"]:-0} + 1 ))
        done < <(awk '/\/libphp[^/ ]*\.so/ {sub(/^[^/]*\//, "/"); print}' "$proc/maps" 2>/dev/null)
    done
    for real in "${!P2_STATUS[@]}"; do
        if (( ${P2_LIVE_BAD[$real]:-0} > 0 )); then
            p2_unknown "${P2_PRINT[$real]}：${P2_COUNT[$real]} 个活动进程中，${P2_LIVE_BAD[$real]} 个映像已替换、读取异常或启动时间未晚于二进制变更；需确认完整重启。"
        elif (( ${P2_COUNT[$real]:-0} > 0 )); then
            if [[ ${P2_STATUS[$real]} == 0 ]]; then
                p2_say "[进程通过] ${P2_PRINT[$real]}：${P2_COUNT[$real]} 个进程与已修复文件一致，启动时间晚于二进制变更。"
            fi
        elif [[ ${P2_PRINT[$real]} == */sbin/php-fpm ]]; then
            p2_say "[未运行] ${P2_PRINT[$real]}：文件已检查，未发现活动 FPM。"
        fi
    done
    for exe in "${!P2_EXTRA[@]}"; do
        p2_unknown "$exe（${P2_EXTRA[$exe]} 个映射/进程）；需单独核验，不能用宝塔文件版本替代。"
    done
}
p2_containers() {
    local runtime listing
    for runtime in docker podman nerdctl; do
        command -v "$runtime" >/dev/null 2>&1 || continue
        if listing=$(timeout 15 "$runtime" ps -a --format '{{.ID}} {{.Image}}' 2>/dev/null); then
            [[ -z $listing ]] || { p2_unknown "$runtime 中有未核验容器："; p2_say "$listing"; }
        else
            p2_unknown "无法读取 $runtime 容器列表。"
        fi
    done
}
p2_result() {
    if (( P2_RISK )); then
        p2_say '[检查未通过] 存在未达到修复版本基线的 PHP；不能视为已修复。'
        return 2
    fi
    if (( P2_FILES == 0 )); then p2_unknown '未找到可检查的宝塔 PHP 文件；这不是没有 PHP 的证明。'; fi
    if (( P2_WEB == 0 )); then p2_unknown '没有已确认使用修复文件的活动宝塔 PHP-FPM；无法确认线上运行时，CLI 进程不能替代。'; fi
    if (( P2_UNKNOWN )); then
        p2_say '[无法确认全部修复] 请处理上面的待核验项；文件通过不等于线上运行时通过。'
        return 3
    fi
    p2_say '[已修复：本次识别范围] 宝塔 CLI/FPM 文件及识别到的活动 PHP 进程均通过 PHP2Shell 检查。'
    return 0
}
p2_main() {
    local cmd path dir branch real after
    while (($#)); do
        case "$1" in
            --site) (($# >= 2)) || { p2_usage; return 1; }; P2_SITE=$2; shift 2 ;;
            --docroot) (($# >= 2)) || { p2_usage; return 1; }; P2_DOCROOT=$2; shift 2 ;;
            --help|-h) p2_usage; return 0 ;;
            *) p2_usage; return 1 ;;
        esac
    done
    if [[ -n $P2_SITE || -n $P2_DOCROOT ]]; then
        [[ -n $P2_SITE && $P2_DOCROOT == /* ]] || { p2_say '--site 与绝对路径 --docroot 必须一起指定。'; return 1; }
        p2_valid_site "$P2_SITE" || { p2_say '域名格式无效。'; return 1; }
        for cmd in curl od tr mktemp chmod rm; do
            command -v "$cmd" >/dev/null || { p2_say "缺少依赖：$cmd"; return 1; }
        done
        trap p2_cleanup_probe EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
    fi
    [[ $(uname -s) == Linux && $EUID -eq 0 ]] || { p2_say '请在 Linux 上以 root/sudo 执行。'; return 1; }
    for cmd in timeout awk stat readlink getconf flock; do
        command -v "$cmd" >/dev/null || { p2_say "缺少依赖：$cmd"; return 1; }
    done
    # Busy locks no longer hide the useful file/process evidence. Preserve unknown.
    p2_check_lock /run/lock/php2shell-fix.lock
    p2_say "PHP2Shell 只读核验 | $(hostname) | $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    p2_say '检查基线：8.2.35 / 8.3.36 / 8.4.27 / 8.5.12；不会安装、改配置或重启。'
    shopt -s nullglob
    for dir in /www/server/php/[0-9]*; do
        [[ -d $dir ]] || continue
        branch=${dir##*/}
        [[ $branch =~ ^[0-9]+$ ]] || continue
        for path in "$dir/bin/php" "$dir/sbin/php-fpm"; do
            [[ -e $path ]] || continue
            p2_check_file "$path" "$branch"
        done
    done
    p2_scan_processes /proc
    p2_containers
    if [[ -n $P2_SITE ]]; then p2_check_site "$P2_SITE" "$P2_DOCROOT"; fi
    # Recheck every file after process inventory to catch concurrent replacement.
    for real in "${!P2_STATUS[@]}"; do
        if [[ ${P2_STATUS[$real]} == 0 ]]; then
            after=$(p2_fingerprint "$real" 2>/dev/null) || after=missing
            [[ $after == "${P2_FINGER[$real]}" ]] || p2_unknown "检查期间二进制发生变化：$real"
        fi
    done
    p2_say '边界：未执行漏洞利用；未核验全部域名、远端后端、磁盘自定义目录或其他用户/命名空间中的容器。'
    p2_say '此结果仅针对这两个 CVE 的补丁与进程证据，不证明未被入侵或网站功能正常。'
    p2_result
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    p2_main "$@"
fi
