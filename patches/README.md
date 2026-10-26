# P0 修复补丁集

本目录是 `dev.zhengjunjie2k` 分支上 5 个 P0 修复的补丁导出，配合 `README.md`
里的分析使用。分支基于 `master` 的 `cd08ed6`。

| # | 提交 | 文件 | 规模 | 一句话 |
|---|------|------|------|--------|
| 0001 | `6a8a053` | `compose/compose.gitea.yml` | +36 / -21 | gitea-db-init 的 shell 被 YAML 折叠破坏，数据库从未创建成功 |
| 0002 | `76a9e06` | `scripts/install.sh` | +36 / -18 | `mkdir -p` 缺少操作数，安装脚本必然中断 |
| 0003 | `0447ec3` | `scripts/deploy.sh` | +26 / -2 | 空服务列表被误判为单服务更新，部署失败且不写 SHA |
| 0004 | `6b574cf` | `scripts/backup.sh` | +6 / -4 | `|| true` 让 Vaultwarden 永远不会被备份 |
| 0005 | `0e67791` | `scripts/restore.sh` | +187 / -23 | 恢复目标库错误 + `gitea restore` 命令不存在 |

> 本文件是第 6 个提交，不包含在 0001-0005 补丁内。

## 如何应用

```bash
git checkout master
git am patches/0001-*.patch patches/0002-*.patch patches/0003-*.patch \
            patches/0004-*.patch patches/0005-*.patch
```

补丁是串行的（0005 依赖 0004 之前的行号），必须按编号顺序应用。
`git am` 会保留提交信息；如果只想看改动，用 `git show` 查看对应提交更直观：

```bash
git show 6a8a053    # 0001
git show 0e67791    # 0005
```

仓库根目录的 `.gitattributes` 已把 `patches/*.patch` 固定为 LF：Windows 上
`core.autocrlf=true` 会把检出内容转成 CRLF，CRLF 补丁在 `git am` / `patch`
下容易报 "patch does not apply"。把补丁复制到 Linux 服务器时也请保持 LF。

## 0001 — gitea-db-init 初始化脚本

**现象**：全新部署时 `gitea-db-init` 容器正常退出（exit 0），Gitea 随后启动失败，
日志为 `database "giteadb" does not exist`。

**根因**：原写法是 `command: >`（YAML 折叠标量）+ 行尾 `\` 续行。折叠标量会把换行
替换成空格，`\` 后面紧跟空格，于是 `\` 变成"转义空格"而不是续行符。用 PyYAML 解析
原文件得到的字符串里含有 `\ -tc`，用 POSIX 分词器切分得到：

```
['psql', '-h', 'postgres', '-U', 'postgres', ' -tc', '"SELECT 1 ..."', ' |', 'grep', '-q', '1', '||', ...]
```

`-tc` 带前导空格后被 psql 当成库名，管道和 `||` 也被粘进同一个单词，所有 SQL 都失败。
而脚本最后一句 `echo 'Gitea database ready'` 仍返回 0，容器以成功退出，
`service_completed_successfully` 条件被满足，错误被完全掩盖。

**改动**：
1. 改成 literal 块（`|`）+ 列表形式 `command: [sh, -c, <script>]`，脚本按真实换行执行；
2. 用 `if ! psql ... | grep -q 1; then ...` 替代 `psql ... | grep -q 1 || psql ...`，
   避免 grep 失败时把两个 psql 的输出/退出码混在一起；
3. `CREATE DATABASE` / `CREATE USER` 的标识符加双引号；
4. 补 `GRANT ALL ON SCHEMA public`：PostgreSQL 15 起 `public` 不再默认给 PUBLIC
   建表权限，缺这条 Gitea 迁移会报 `permission denied for schema public`。

**行为变化**：初始化改为幂等（已存在的库/用户不会重复创建）。对已部署的环境，
下次 `up -d` 会重跑这个一次性容器并补授权，不会破坏数据。

**验证**：`yaml.safe_load` 后 `command` 是长度 3 的列表，第 3 个元素是完整的多行脚本；
`bash -n` 语法检查通过。

## 0002 — install.sh 目录创建与属主

**现象**：`./scripts/install.sh` 打印 `Creating directories...` 之后立即退出，
后续目录、权限、拉镜像、启动全部不执行。

**根因**：`mkdir -p` 单独成行，随后每个路径各占一行——它们被当成命令执行。
脚本头部是 `set -euo pipefail`，`mkdir` 因缺少操作数返回 1，函数直接终止。

**改动**：
1. 恢复成 `mkdir -p <11 个路径>`；
2. 新增 `fix_permissions()`：按 `PUID:PGID` 对 `appdata/code-server` 与
   `data/workspace` 执行 `chown -R`（code-server 容器以该用户运行，root 创建的
   挂载目录它写不进去）；
3. 非 root 执行时只告警并打印可手工执行的 chown 命令，不中断安装。

**验证**：`bash -n` 通过；`fix_permissions` 在 `PUID` 未设、非 root 两种情况下都
`return 0`。

## 0003 — deploy.sh 决策逻辑

**现象 A**：只要提交里有"映射表未覆盖"的文件（`scripts/lib.sh`、`scripts/backup.sh`、
`.github/workflows/deploy.yml` 等），部署失败，且 `.state/last_deployed_sha` 不更新，
下次重跑继续失败。

**根因 A**：`SERVICES` 为空时，`printf "%s\n" "${SERVICES[@]}"` 仍输出一个空行，
`mapfile` 于是得到**一个空字符串元素**，长度判断为 1，走成
`update-service.sh ""` → usage → exit 1。

**现象 B**：`.state` 里的 SHA 被 gc 或强推覆盖后，`git diff` 失败被 `|| true` 吞掉，
被当作"无变更"跳过，且不写 SHA，永久卡住。

**改动**：
1. `SERVICES` 为空时跳过 `mapfile`，让"无服务匹配 → 全量部署"的兜底分支生效；
2. `git diff` 失败显式识别，`FORCE_FULL_DEPLOY=true` 直接全量部署；
3. "无文件变更"分支也写回 SHA（避免空提交导致每次都重新判断）。

**验证**（假 docker，真实 bash 5.3 + 真实 git 仓库）：

| 场景 | 结果 |
|------|------|
| 无变更 | skip，exit 0 |
| 仅改 README.md | "Only documentation changed"，exit 0 |
| 改 `scripts/lib.sh`（未映射） | "no specific service match — full deploy"，exit 0 |
| 改 `compose/compose.npm.yml` | "Updating single service: npm"，健康检查通过，exit 0 |
| `.state` 写入不存在的 SHA | WARN + 全量部署，exit 0 |
| 旧代码做同样操作（改 lib.sh） | `Updating single service: ` + usage + **exit 1**，SHA 未写入 |

## 0004 — backup.sh

**现象**：`data/backup/vaultwarden/` 永远是空的。

**根因**：`if ! docker ps -a ... | grep -wq "vaultwarden" || true; then` ——
`|| true` 让整个条件恒为真，无论容器是否存在都 `return 0`。

**改动**：
1. 去掉 `|| true`（`if` 的条件本身不受 `set -e` 影响，原来担心的中断并不会发生）；
2. `gitea dump` 增加 `-w /tmp`：官方文档要求 dump 在容器内可写的临时目录执行，
   否则打包阶段可能因权限失败。

**验证**：`bash` 实测"容器不存在 → SKIP"与"容器存在 → 备份"两条分支行为正确。

**已知未改**：`gitea dump` 仍在 Gitea 运行中执行，官方建议停机以保证一致性。
停机属于可用性取舍，留到下一批处理（可配合 `compose stop gitea` + `trap` 恢复）。

## 0005 — restore.sh

**现象 1**：`restore.sh postgres giteadb_xxx.sql.gz` 把 giteadb 的表建到 `postgres` 库；
SQL 中途报错被忽略，最后仍打印 "restore completed"。

**现象 2**：`restore.sh gitea xxx.zip` 调用 `gitea restore --from ...` ——
Gitea 没有 `restore` 子命令（官方文档：目前没有恢复命令，只能手工解压、复制文件、
导入 SQL），这条路径必然失败。

**改动**：
1. `restore_postgres` 增加可选第三个参数 `[database]`，缺省时按备份文件名
   `<db>_<YYYYmmdd_HHMMSS>.sql.gz` 推断，恢复前校验目标库存在，psql 加
   `-v ON_ERROR_STOP=1`，连接方式与 `backup.sh` 一致（`-h 127.0.0.1` + PGPASSWORD）；
2. `restore_gitea` 按官方 Docker 流程重写：
   解压 → 停 Gitea → `pg_dump` 快照当前库 → 重建 `public` schema → **以 gitea 用户**
   导入 `gitea-db.sql`（保证表属主正确）→ 把 `data/`、`custom/`、`repos/` 复制到
   宿主机挂载目录（旧目录改名为 `appdata/gitea.bak.<时间戳>`）→ 启动 → 轮询
   `/api/health` → 重建 git hooks 与 authorized_keys；
3. `main` 支持 2-3 个参数，`usage` 补充 vaultwarden 与 database 说明。

**风险**：这是本次唯一会改数据的脚本。防护措施：交互确认（输入 yes）、恢复前自动
`pg_dump` 快照、旧数据目录改名保留、健康检查失败立即退出并打印旧数据位置。

**失败时的状态**：SQL 导入中途失败会因 `set -e` 直接中止，此时 Gitea 保持停止；
快照在 `data/backup/postgres/<GITEA_DB_NAME>_pre_restore_<时间戳>.sql.gz`，可据此
回滚。`restore.sh postgres` 同理，失败后需要手工 `compose start gitea`。

**验证**：`bash -n` 通过；文件名推断逻辑实测 `giteadb_20261026_174000.sql.gz → giteadb`、
`my_app_... → my_app`、`backup.sql.gz → postgres`。
**未验证**：完整的 Docker/PostgreSQL 流程需要真实环境，建议先在测试机演练一次。

## 验证记录汇总

| 项目 | 方法 | 结果 |
|------|------|------|
| YAML 结构 | PyYAML 6.0.3 解析 6 个 compose 文件与 workflow | 通过 |
| 旧命令字符串 | PyYAML + shlex 分词 | 复现 `' -tc'`、`' |'` 错误参数 |
| Shell 语法 | `bash -n`（Git for Windows bash 5.3）14 个脚本 | 全部通过 |
| 关键语义 | 空数组 mapfile、文件名推断、`|| true`、`set -e` diff | 全部符合预期 |
| deploy.sh 决策矩阵 | 假 `docker` + 真实 git 仓库，6 个场景 | 全部 exit 0；旧代码同场景 exit 1 |
| 补丁可应用性 | 干净克隆上 `git am` 5 个补丁 | 通过，与分支 tip 无差异 |

## 回滚

- 单个补丁：`git revert <sha>`
- 整个分支：`git reset --hard master`
- 服务器侧回滚：恢复 `.state/last_deployed_sha` 到本次之前的 SHA，或直接
  `git checkout master && ./scripts/update-all.sh`

## 下一批（未包含）

1. Gitea：`INSTALL_LOCK=true`、关闭公开注册、用 CLI 创建管理员（`GITEA_ADMIN_*` 无效）
2. `healthcheck.sh` 补 code-server / vaultwarden / welcome，探活统一 `/healthz`
3. 全服务加日志轮转；备份补 `appdata/npm`、`.env`、`pg_dumpall --globals-only`
4. `.env` 用 Compose `--env-file` 解析，避免 `source` 吞掉 `$`
5. 文档同步：Vaultwarden 章节、端口 2222、NPM 2.16.0、master 分支、LICENSE
6. CI 加 `docker compose config -q` 与 `shellcheck`
