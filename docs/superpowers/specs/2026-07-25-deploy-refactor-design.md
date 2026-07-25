# Docker Server Stack 部署流程重构设计

## 目标

将现有单体 `docker-compose.yml` 拆分为分层 Compose 结构，并引入基于 Git diff 的智能部署流程，实现 **GitHub Actions 只触发，服务器脚本负责判断和执行**。

## 目录结构

```
docker-server-stack/
├── compose/
│   ├── compose.base.yml          # name + networks（骨架）
│   ├── compose.infra.yml         # PostgreSQL 数据库
│   ├── compose.gitea.yml         # Gitea + gitea-db-init
│   ├── compose.npm.yml           # Nginx Proxy Manager
│   ├── compose.code-server.yml   # VS Code Server
│   ├── compose.welcome.yml       # 默认欢迎页（nginx）
│   └── compose.override.yml      # 本地覆盖（.gitignore）
├── scripts/
│   ├── lib.sh                    # 共享函数库
│   ├── deploy.sh                 # 智能部署入口
│   ├── update-service.sh         # 单服务更新
│   ├── update-all.sh             # 全量更新
│   ├── healthcheck.sh            # 健康检查（重写）
│   ├── install.sh                # 安装（更新 compose 路径）
│   ├── update.sh                 # 保留，委托给 deploy.sh
│   ├── backup.sh                 # 保留（更新 compose 路径）
│   ├── restore.sh                # 保留（更新 compose 路径）
│   ├── create-db.sh              # 保留
│   └── services/
│       ├── gitea.sh
│       ├── npm.sh
│       ├── code-server.sh
│       └── postgres.sh
├── .state/
│   └── last_deployed_sha         # 上次成功部署 SHA（自动生成）
├── .github/workflows/
│   └── deploy.yml                # GitHub Actions
└── docker-compose.yml            # 软兼容入口
```

## Compose 文件拆分

### compose.base.yml

```yaml
name: ${COMPOSE_PROJECT_NAME}

networks:
  proxy_network:
    name: proxy_network
    driver: bridge
  backend_network:
    name: backend_network
    driver: bridge
```

所有服务共享此骨架。无 `services` 节。

### compose.infra.yml

PostgreSQL 数据库：
- `postgres` 服务（无变动，从原 yml 直接提取）
- 网络：`backend_network`

### compose.gitea.yml

Gitea 相关：
- `gitea-db-init` — 自动创建数据库和用户
- `gitea` — Gitea 服务
- 网络：`proxy_network` + `backend_network`

### compose.npm.yml

Nginx Proxy Manager：
- `npm` 服务
- 网络：`proxy_network`

### compose.code-server.yml

VS Code Server：
- `code-server` 服务
- 网络：`proxy_network`

### compose.welcome.yml

默认欢迎页：
- `welcome` 服务
- 网络：`proxy_network`

### compose.override.yml

本地覆盖配置，用于开发环境差异。**不提交到 Git**（已在 `.gitignore` 中）。

## 脚本设计

### lib.sh — 共享函数库

提供所有脚本共用的基础设施：

```bash
# 路径
SCRIPT_DIR → scripts/
PROJECT_DIR → repo root

# compose 命令组装
compose_cmd() → "docker compose -f compose/base.yml -f compose/infra.yml ..."

# 通用函数
log() / info() / warn() / error()
load_env() — 加载 .env
check_docker() / check_compose()
```

### deploy.sh — 智能部署（核心入口）

```
算法：
1. 读取 CURRENT_SHA = git rev-parse HEAD
2. 读取 LAST_SHA = cat .state/last_deployed_sha（首次=初始 commit）
3. CHANGED = git diff --name-only LAST_SHA..CURRENT_SHA
4. 分类决策：
   ├─ 仅 .md / .txt / 非代码文件 → echo "Docs only, skip" && exit 0
   ├─ .env / compose.base.yml / compose.override.yml 变更
   │   └─ 全量部署（update-all.sh）
   ├─ compose.npm.yml 变更 → update-service.sh npm
   ├─ compose.gitea.yml 变更 → update-service.sh gitea
   ├─ compose.code-server.yml 变更 → update-service.sh code-server
   ├─ compose.infra.yml 变更 → update-service.sh postgres
   ├─ compose.welcome.yml 变更 → docker compose up -d welcome
   ├─ scripts/services/npm.sh 变更 → update-service.sh npm
   ├─ scripts/services/gitea.sh 变更 → update-service.sh gitea
   ├─ 多服务变更 / 无法判断 → 全量部署（安全兜底）
5. 成功后：echo "$CURRENT_SHA" > .state/last_deployed_sha
```

### update-service.sh — 单服务更新

```bash
# 用法: update-service.sh <service-name>
# 1. 读取 scripts/services/<service>.sh
# 2. 执行对应脚本定义的 update() 函数
# 3. 可选健康检查
# 4. 清理旧镜像
```

### update-all.sh — 全量更新

```bash
# 1. docker compose pull
# 2. docker compose up -d --remove-orphans
# 3. 健康检查
# 4. 清理旧镜像
```

### services/*.sh — 服务映射脚本

每个文件定义该服务的更新逻辑，通过 `update()` 函数导出：

- `gitea.sh`: `docker compose pull gitea && docker compose up -d gitea`
- `npm.sh`: `docker compose pull npm && docker compose up -d npm`
- `code-server.sh`: `docker compose pull code-server && docker compose up -d code-server`
- `postgres.sh`: `docker compose pull postgres && docker compose up -d postgres`

### healthcheck.sh — 重写

沿用现有检查逻辑，但：
- 使用 `compose_cmd()` 替代裸 `docker compose` 
- 使用 `set -euo pipefail`
- 引入 lib.sh

## GitHub Actions

### .github/workflows/deploy.yml

```yaml
name: Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: SSH into server and deploy
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SERVER_SSH_KEY }}
          script: |
            cd /data/server
            git pull --ff-only
            chmod +x scripts/*.sh scripts/services/*.sh
            ./scripts/deploy.sh
```

## .gitignore 更新

新增忽略项：
```
# 状态文件
.state/

# Compose 本地覆盖
compose/compose.override.yml
```

## 向后兼容

- `docker-compose.yml` 保留在根目录作为入口（可选），或保留一个软兼容的版本调用 `compose_cmd()`
- 所有数据目录：`appdata/`、`data/` 路径不变
- 现有 `.env` 格式不变
- 现有脚本签名不变（`./scripts/backup.sh`、`./scripts/restore.sh` 等照常工作）

## 扩展新服务

新增服务只需三步：
1. 创建 `compose/compose.<service>.yml`
2. 创建 `scripts/services/<service>.sh`
3. 在 `deploy.sh` 的 diff 映射表中加一行
