#!/usr/bin/env bash
# PHP2Shell package remediation for Ubuntu. See README.md for scope.
set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

MODE=check
PENDING=0
PACKAGES=()
SERVICES=()
RUNTIMES=0
OS_ID=unknown
OS_VERSION=unknown
WORKDIR=''

say() { printf '%s\n' "$*"; }
pending() { say "[待处理] $*"; PENDING=1; }
die() { say "[失败] $*" >&2; exit 1; }
release_lock() {
    flock -u 9 2>/dev/null || true
    exec 9>&-
}
on_error() {
    local rc=$1 line=$2
    printf '[失败] 行 %s，退出码 %s；修复未完成。日志：%s\n' "$line" "$rc" "$WORKDIR/run.log" >&2
    exit "$rc"
}

usage() {
    cat <<'HELP'
用法：sudo bash fix-php2shell.sh --apply
      sudo bash fix-php2shell.sh --check
--apply 备份配置、升级现有 PHP 软件包、重启相关服务并核验。
--check 只读盘点与补丁核验（默认）；不刷新软件源。
支持 Ubuntu apt/dpkg 安装。容器、宝塔、自编译及自定义服务需另行处理。
退出码：0=本次受支持范围核验通过；1=执行失败；2=有待处理项。
HELP
}

# Only release versions qualify; do not accept an RC or an unknown future branch.
upstream_fixed() {
    local version=${1#*:} major minor patch suffix floor
    [[ $version =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(.*)$ ]] || return 1
    major=${BASH_REMATCH[1]}; minor=${BASH_REMATCH[2]}
    patch=${BASH_REMATCH[3]}; suffix=${BASH_REMATCH[4]}
    [[ -z $suffix || $suffix == -* || $suffix == +* ]] || return 1
    case "$major.$minor" in
        8.2) floor=35 ;; 8.3) floor=36 ;; 8.4) floor=27 ;; 8.5) floor=12 ;;
        *) return 1 ;;
    esac
    (( 10#$patch >= floor ))
}

# Exact Ubuntu version families from USN-8948-1. A PPA suffix is not evidence.
ubuntu_fixed() {
    local source=$1 version=${2#*:} floor pattern
    [[ $OS_ID == ubuntu ]] || return 1
    case "$OS_VERSION/$source" in
        22.04/php8.1) floor=8.1.2-1ubuntu2.28; pattern='^8\.1\.2-1ubuntu2\.[0-9]+$' ;;
        24.04/php8.3) floor=8.3.6-0ubuntu0.24.04.13; pattern='^8\.3\.6-0ubuntu0\.24\.04\.[0-9]+$' ;;
        26.04/php8.5) floor=8.5.4-0ubuntu1.5; pattern='^8\.5\.4-0ubuntu1\.[0-9]+$' ;;
        26.10/php8.5) floor=8.5.9-0ubuntu2.1; pattern='^8\.5\.9-0ubuntu2\.[0-9]+$' ;;
        *) return 1 ;;
    esac
    [[ $version =~ $pattern ]] && dpkg --compare-versions "$version" ge "$floor"
}

inventory_packages() {
    dpkg-query -W -f='${db:Status-Status}\t${binary:Package}\t${Version}\t${source:Package}\t${source:Version}\n' > "$WORKDIR/packages.tsv"
    PACKAGES=()
    local status package version source source_version base
    while IFS=$'\t' read -r status package version source source_version; do
        [[ $status == installed ]] || continue
        base=${package%%:*}
        if [[ $base =~ ^php([0-9]+\.[0-9]+)?(-|$) || $base =~ ^libapache2-mod-php ]]; then
            # Default-version metapackages may pull a different PHP branch.
            [[ $source != php-defaults ]] || continue
            PACKAGES+=("$package")
            printf '  %s %s\n' "$package" "$version"
        fi
    done < "$WORKDIR/packages.tsv"
}

validate_plan() {
    local action package rest branch
    while read -r action package rest; do
        [[ $action == Inst ]] || continue
        if [[ $package =~ ^(php|libapache2-mod-php)([0-9]+\.[0-9]+) ]]; then
            branch=${BASH_REMATCH[2]}
            if ! awk -F '\t' -v source="php$branch" '$1 == "installed" && $4 == source { found=1 } END { exit !found }' "$WORKDIR/packages.tsv"; then
                say "[拒绝计划] $package 会引入未安装的 PHP $branch 分支。" >&2
                return 1
            fi
        fi
    done < "$WORKDIR/apt-plan.txt"
}

verify_packages() {
    local status package version source source_version
    RUNTIMES=0
    while IFS=$'\t' read -r status package version source source_version; do
        [[ $status == installed && $source =~ ^php[0-9]+\.[0-9]+$ ]] || continue
        RUNTIMES=$((RUNTIMES + 1))
        if upstream_fixed "$source_version" || ubuntu_fixed "$source" "$source_version"; then
            say "[补丁通过] $package $version (源码包 $source $source_version)"
        else
            pending "$package $version：未达到已核实修复版本；检查安全源/PPA/hold 状态及供应商公告。"
        fi
    done < "$WORKDIR/packages.tsv"
    if (( RUNTIMES == 0 )); then
        pending '未发现可核验的 PHP 核心软件包；不能据此断定整台服务器没有 PHP。'
    fi
}

managed_php_file() {
    local path=$1 owner status package version source source_version
    # dpkg-query matches patterns: reject glob metacharacters in process paths.
    [[ $path != *'['* && $path != *'?'* && $path != *'*'* ]] || return 1
    owner=$(dpkg-query -S "$path" 2>/dev/null) || return 1
    while IFS=$'\t' read -r status package version source source_version; do
        [[ $status == installed && $source =~ ^php[0-9]+\.[0-9]+$ ]] || continue
        [[ $owner == "$package: "* || $owner == "${package%%:*}: "* ]] && return 0
    done < "$WORKDIR/packages.tsv"
    return 1
}

discover_services() {
    SERVICES=()
    if ! systemctl list-units --type=service --state=active --no-legend --plain > "$WORKDIR/services.txt"; then
        pending '无法查询 systemd；自动重启无法完成。'
        return
    fi
    local unit rest
    while read -r unit rest; do
        case "$unit" in
            php[0-9]*-fpm.service|php-fpm.service) SERVICES+=("$unit") ;;
            apache2.service)
                if [[ -d /etc/apache2/mods-enabled ]] && compgen -G '/etc/apache2/mods-enabled/php*.load' >/dev/null; then
                    SERVICES+=("$unit")
                fi ;;
        esac
    done < "$WORKDIR/services.txt"
    if ((${#SERVICES[@]})); then
        printf '[相关活动服务] %s\n' "${SERVICES[@]}"
    fi
}

inventory_extra() {
    local path runtime listing proc exe name lib cg unit seen=0
    local -A unmanaged_counts=()
    shopt -s nullglob
    # Bounded checks: no full disk traversal and no execution of discovered binaries.
    for path in /usr/local/bin/php* /usr/local/sbin/php-fpm* /opt/*/bin/php* \
        /www/server/php/*/bin/php /www/server/php/*/sbin/php-fpm \
        /usr/local/lsws/lsphp*/bin/lsphp; do
        [[ -f $path && -x $path ]] || continue
        if ! managed_php_file "$path"; then
            pending "非系统 PHP 候选文件：$path；本脚本不会修改。"
        fi
    done
    for runtime in docker podman nerdctl; do
        command -v "$runtime" >/dev/null 2>&1 || continue
        if listing=$(timeout 15 "$runtime" ps -a --format '{{.ID}} {{.Image}}' 2>/dev/null); then
            if [[ -n $listing ]]; then
                pending "$runtime 中存在未核验容器（包括已停止容器），需更新 PHP/应用镜像并重建："
                say "$listing"
            fi
        else
            pending "无法盘点 $runtime 容器。"
        fi
    done
    if command -v snap >/dev/null 2>&1; then
        if listing=$(timeout 20 snap list 2>/dev/null); then
            listing=$(awk 'NR > 1 && $1 !~ /^(bare|core[0-9]*|snapd)$/ {print $1}' <<< "$listing")
            [[ -z $listing ]] || pending "Snap 应用需单独核验 PHP（非直接认定存在漏洞）：$listing"
        else
            pending '无法列出 Snap 应用；仅安装 snap 命令不能证明有 PHP。'
        fi
    fi
    for runtime in crictl lxc-ls machinectl; do
        if command -v "$runtime" >/dev/null 2>&1; then
            pending "检测到 $runtime：其中的 PHP 不属于本次 apt 修复范围，请单独核验。"
        fi
    done
    # Process executable and loaded module paths, without printing command-line secrets.
    for proc in /proc/[0-9]*; do
        exe=$(readlink "$proc/exe" 2>/dev/null) || continue
        name=${exe##*/}
        if [[ $name =~ ^(php([0-9.]+)?|php-fpm([0-9.]+)?|php-cgi([0-9.]+)?|lsphp.*|frankenphp.*|caddy)(\ \(deleted\))?$ ]]; then
            if ! managed_php_file "$exe"; then
                unmanaged_counts["$exe"]=$(( ${unmanaged_counts["$exe"]:-0} + 1 ))
            else
                seen=1
                cg=$(cat "$proc/cgroup" 2>/dev/null) || { pending "无法读取 PID ${proc##*/} cgroup"; continue; }
                unit=''
                for path in "${SERVICES[@]}"; do
                    [[ $cg == *"/$path" || $cg == *"/$path/"* ]] && unit=$path
                done
                if [[ -z $unit ]]; then
                    pending "PID ${proc##*/} 不归本次识别的 FPM/Apache 服务管理：$exe；需单独重启并核验。"
                fi
            fi
        fi
        [[ -r $proc/maps ]] || { pending "无法读取 PID ${proc##*/} 内存映射"; continue; }
        while IFS= read -r lib; do
            [[ -n $lib ]] || continue
            if ! managed_php_file "$lib"; then
                pending "PID ${proc##*/} 加载了未核验 PHP 模块：$lib"
            else
                seen=1
                cg=$(cat "$proc/cgroup" 2>/dev/null) || cg=''
                if [[ ! " ${SERVICES[*]} " == *' apache2.service '* ||
                    ! ( $cg == *'/apache2.service' || $cg == *'/apache2.service/'* ) ]]; then
                    pending "PID ${proc##*/} 的 PHP 模块不属于已识别的活动 Apache，请单独重启并核验。"
                fi
            fi
        done < <(awk '/\/libphp[^/ ]*\.so/ { sub(/^[^/]*\//, "/"); print }' "$proc/maps" 2>/dev/null)
    done
    for exe in "${!unmanaged_counts[@]}"; do
        pending "非受支持的 PHP/嵌入式运行时候选：$exe（${unmanaged_counts["$exe"]} 个进程，合并显示）"
    done
    if (( seen == 0 )); then
        say '[范围提示] 未识别到受支持的活动 PHP Web 进程；这不是外网站点或全部安装的安全证明。'
    fi
    shopt -u nullglob
}

preflight_services() {
    local unit branch binary
    for unit in "${SERVICES[@]}"; do
        case "$unit" in
            php[0-9]*-fpm.service)
                branch=${unit#php}; branch=${branch%-fpm.service}
                binary=/usr/sbin/php-fpm$branch
                [[ -x $binary ]] || die "找不到 $binary；停止自动重启。"
                "$binary" -t || die "$unit 配置校验失败。" ;;
            php-fpm.service) die '无法确定非标准 php-fpm.service 对应的版本；请人工核验。' ;;
            apache2.service) apache2ctl configtest || die 'Apache 配置校验失败。' ;;
        esac
    done
}

main() {
    if (($# > 1)); then usage; return 1; fi
    case "${1:---check}" in
        --check) MODE=check ;; --apply) MODE=apply ;;
        -h|--help) usage; return 0 ;; *) usage; return 1 ;;
    esac
    [[ $(uname -s) == Linux ]] || die '请在目标 Ubuntu 服务器执行。'
    (( EUID == 0 )) || die '请使用 sudo bash fix-php2shell.sh --apply（或 --check）。'
    [[ -r /etc/os-release ]] || die '缺少 /etc/os-release。'
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID=${ID:-unknown}; OS_VERSION=${VERSION_ID:-unknown}
    [[ $OS_ID == ubuntu ]] || die "本脚本支持 Ubuntu；当前为 $OS_ID $OS_VERSION。"
    local cmd
    for cmd in apt-get dpkg dpkg-query systemctl flock tar timeout awk tee; do
        command -v "$cmd" >/dev/null || die "缺少依赖：$cmd"
    done
    [[ ! -e /.dockerenv && ! -e /run/.containerenv ]] || die '检测到容器环境，请从宿主机更新镜像并重建容器。'
    exec 9>/run/lock/php2shell-fix.lock
    flock -n 9 || die '已有修复/检查任务正在运行。'
    trap release_lock EXIT
    if [[ $MODE == apply ]]; then
        WORKDIR=$(mktemp -d /var/log/php2shell-fix.XXXXXXXX)
    else
        WORKDIR=$(mktemp -d /tmp/php2shell-check.XXXXXXXX)
    fi
    exec > >(tee -a "$WORKDIR/run.log" 9>&-) 2>&1
    trap 'on_error "$?" "$LINENO"' ERR
    say "PHP2Shell | Ubuntu $OS_VERSION | 模式 $MODE | $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    say "日志与记录：$WORKDIR（仅 root 可读，可能含配置敏感信息，请勿上传）"
    say '本脚本核验 CVE-2026-109618 / CVE-2026-109619 的软件包补丁，不检查历史入侵。'
    inventory_packages
    discover_services
    if [[ $MODE == apply && ${#PACKAGES[@]} -gt 0 ]]; then
        local -a configs=()
        [[ ! -d /etc/php ]] || configs+=(etc/php)
        [[ ! -d /etc/apache2 ]] || configs+=(etc/apache2)
        if ((${#configs[@]})); then
            tar -C / -czf "$WORKDIR/config-before.tar.gz" -- "${configs[@]}"
        fi
        cp "$WORKDIR/packages.tsv" "$WORKDIR/packages-before.tsv"
        cp "$WORKDIR/services.txt" "$WORKDIR/services-before.txt"
        preflight_services
        say '[升级] 更新软件源并仅升级已安装 PHP 包；网站可能短暂中断。'
        apt-get -o APT::Update::Error-Mode=any update 9>&-
        apt-get -s --only-upgrade --no-remove install -- "${PACKAGES[@]}" > "$WORKDIR/apt-plan.txt" 9>&-
        cat "$WORKDIR/apt-plan.txt"
        validate_plan || die '升级计划包含新 PHP 分支，请检查软件源和依赖后重试。'
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
            apt-get -y --only-upgrade --no-remove -o Dpkg::Options::=--force-confold install -- "${PACKAGES[@]}" 9>&-
        inventory_packages
        # A restart, rather than a graceful reload, replaces every old worker.
        preflight_services
        local unit
        for unit in "${SERVICES[@]}"; do
            say "[重启] $unit"
            systemctl restart "$unit" 9>&-
            systemctl is-active --quiet "$unit" || die "$unit 重启后未正常运行。"
        done
        discover_services
    fi
    verify_packages
    inventory_extra
    say '盘点边界：自定义目录、远端 PHP、rootless/其他命名空间及非标准嵌入式运行时可能遗漏。'
    if (( PENDING )); then
        say "[未完成] 存在待处理项；不要视为整台服务器已修复。日志：$WORKDIR/run.log"
        trap - ERR
        return 2
    fi
    say "[通过] 本次识别的 apt PHP 核心包已达到已知补丁版本；$MODE。"
    say "请确认各实际域名、登录和上传功能正常。日志：$WORKDIR/run.log"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
