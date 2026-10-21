# Ubuntu PHP2Shell 修复脚本

针对 CVE-2026-109618 / CVE-2026-109619，提供 Ubuntu apt PHP 和标准宝塔 PHP 8.2 两个独立入口。默认只检查，传入 `--apply` 才升级。

## 宝塔 PHP 8.2（路径 /www/server/php/82）

如果原脚本报告 `/www/server/php/82`，请使用以下专用入口；apt 更新不会更新这个目录。

```bash
(f=$(mktemp) && trap 'rm -f -- "$f"' EXIT && curl -fL --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/m16a4666/php2shell-fix/main/fix-bt-php82.sh -o "$f" && sudo bash "$f" --apply)
```

脚本只更新标准宝塔 PHP **8.2**，不修改网站绑定、不跨分支安装：

- 核验 Ubuntu、标准宝塔安装路径、CLI/FPM 版本、现有 FPM 配置及扩展加载情况。
- 从宝塔官方 HTTPS 下载 `install/0/php.sh`，与本仓库已审阅版本的 SHA-256 比对，并确认目标版本至少 8.2.35；内容变化则停止，需重新核查更新。
- 在 `/var/log/php2shell-bt82.*` 备份 PHP 8.2 目录（包含配置及扩展，排除 src 构建目录），保留升级前模块列表及 PID。
- 调用官方脚本 **`update 8.2`**。不使用会清空目录的 `install` 操作，不使用尚未核实补丁的“极速安装”脚本。
- 再次核验 CLI/FPM 文件版本、主配置校验和、扩展列表及 FPM 配置。原来活动的 FPM 会完整重启，原来停止的 FPM 恢复停止状态。网站在安装/重启阶段可能短暂中断；编译耗时取决于服务器性能。

如编译失败且原来活动的 FPM 停止，脚本会在配置可用时尝试启动当前运行时，并仍然报未完成；不会盲目覆盖备份。**目录备份不是整机快照，官方更新器可能安装/更新系统依赖或公共库，备份不支持完整自动回滚。** 官方更新器有自己的网络下载及诊断上报行为。

成功只表示这个 PHP 8.2 实例通过上述检查；其他版本、容器及实际站点功能仍需单独核验。脚本及官方更新器未在用户实际生产服务器上预先运行验证。

官方编译更新脚本来源：[download.bt.cn/install/0/php.sh](https://download.bt.cn/install/0/php.sh)。截至 2026-10-21，本次审阅的脚本声明目标为 8.2.35，而 `install/1/php.sh` 仍声明 8.2.34。

## 直接运行

在每台目标 Ubuntu 服务器运行（root 可省略 sudo）：

```bash
(f=$(mktemp) && trap 'rm -f -- "$f"' EXIT && curl -fL --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/m16a4666/php2shell-fix/main/fix-php2shell.sh -o "$f" && sudo bash "$f" --apply)
```

需要 curl。下载失败不会执行；建议使用聊天中提供的固定提交及 SHA-256 校验指令。没有向开发者上传服务器信息的功能。

只检查：

```bash
(f=$(mktemp) && trap 'rm -f -- "$f"' EXIT && curl -fL --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/m16a4666/php2shell-fix/main/fix-php2shell.sh -o "$f" && sudo bash "$f" --check)
```

## 实际操作

1. 检查 Ubuntu、root、依赖，使用 flock 防止本脚本并行运行。
2. 枚举已安装 PHP 包，包括多版本 FPM、CLI、CGI、Apache 模块及扩展。
3. 备份 `/etc/php`、`/etc/apache2`，记录升级前包版本、活动服务、升级计划及日志。目录在 `/var/log/php2shell-fix.*`，仅 root 可读。检查模式记录在 `/tmp/php2shell-check.*`。
4. 刷新现有 apt 软件源，只升级已安装的 PHP 包及必要依赖，跳过可能切换默认分支的 `php-defaults` 元包，并拒绝模拟计划中出现的新 PHP 分支；不添加 PPA、不执行全系统升级、不移除软件包。现有配置通过 `--force-confold` 保留。软件包维护脚本仍可能执行标准配置迁移或重启。
5. 校验标准 FPM/Apache 配置，完整重启原来活动的 PHP-FPM 和启用 mod_php 的 Apache，再检查服务状态。**网站可能短暂中断。** 软件包有 hold、源错误或升级/重启失败会报错，不强行解除限制。
6. 按源码包版本核验各 PHP 核心包；再扫描常见自定义安装位置、活动进程和 libphp 映射，列出容器/其他运行时的待处理项。

重复运行会重新检查软件源、核验并重启相关活动服务。脚本不创建公网 phpinfo 页面，也不发送漏洞利用请求。

## 修复判定

截至 2026-10-21，已核实上游最低修复版本：8.2.35、8.3.36、8.4.27、8.5.12。只接受正式版和相应分支后续补丁版，未知分支和候选版不推断安全。

Ubuntu USN-8948-1 的回补版本也可通过：

| Ubuntu | PHP 源码包 | 最低修复包版本 |
| --- | --- | --- |
| 22.04 | php8.1 | 8.1.2-1ubuntu2.28 |
| 24.04 | php8.3 | 8.3.6-0ubuntu0.24.04.13 |
| 26.04 | php8.5 | 8.5.4-0ubuntu1.5 |
| 26.10 | php8.5 | 8.5.9-0ubuntu2.1 |

回补判定限定发行版与包版本格式，不把任意 PPA 后缀当作修复凭据。未列出的回补版本可能已修复，但脚本会要求人工确认，不会猜测。

**关闭 `session.upload_progress.enabled` 或调大 `memory_limit` 不是这两个漏洞的完整修复。** 脚本采用软件更新，不自动改变网站上传、会话和内存配置。

## 范围与退出码

- `0`：本次识别的 apt PHP 核心包达到已知修复版本，未发现需另行处理的候选项；apply 模式还完成了相关已识别服务的重启。
- `1`：执行失败。查看日志处理软件源、配置、依赖或服务问题后重跑。
- `2`：仍有未修复或无法核实的组件、容器、自定义进程，或没有可核验的 PHP 核心包。**不得当作整机修复成功。**

宝塔、1Panel 自定义 PHP、自编译、LiteSpeed、FrankenPHP、Docker/Podman/Kubernetes、Snap、rootless 容器和远端反代后端不能通过升级宿主机 apt 包来完成修复。脚本只报告部分常见候选；即使容器是非 PHP 应用，也会保守要求单独确认。容器应更新应用/PHP 镜像并重建；面板应在面板中更新实际使用的全部 PHP 版本。

本脚本不是穷尽式环境发现工具。自定义目录、其他用户/命名空间、远端服务及未知嵌入式运行时可能遗漏；返回 0 仅针对上述范围。CLI 版本通过也不等于域名背后的 PHP 已验证。完成后请核验各实际域名、登录、上传等功能，并检查实际后端部署。没有补丁时应限制受影响服务的公网访问，直到能完成更新。

备份仅包含配置和版本记录，**不是软件包/数据/系统快照，不支持自动降级回滚**。出现故障可依据日志和配置备份修复；不要把包含配置密钥的备份或日志上传到 GitHub。脚本也不会判断或清理历史入侵。

## 来源

- [PHP 官方安全公告及修复方式](https://www.php.net/archive/2026.php#2026-10-21-1)
- [CVE-2026-109618 官方公告](https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w)
- [CVE-2026-109619 官方公告](https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp)
- [Ubuntu USN-8948-1](https://ubuntu.com/security/notices/USN-8948-1)

## 验证

```bash
for f in *.sh tests/*.sh; do bash -n "$f"; done
shellcheck *.sh tests/*.sh
bash tests/test.sh
bash tests/test-bt.sh
```

测试覆盖修复版本边界、Ubuntu 回补、候选版/PPA 拒绝、CLI 已修复但 FPM 未修复、未安装核心包、软件包归属和服务发现。测试使用桩，不会在本机升级软件或重启服务。实际生产站点可用性仍需运行后确认。
