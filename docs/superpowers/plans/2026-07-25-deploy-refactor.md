# Docker Server Stack 部署流程重构 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 将单体 `docker-compose.yml` 拆分为分层 Compose 结构，引入基于 Git diff 的智能部署，实现 GitHub Actions 只触发、服务器脚本判断执行。

**架构：** 6 个分层 Compose 文件（base/infra/gitea/npm/code-server/welcome）+ 共享函数库 lib.sh + 按服务拆分的 service 脚本 + deploy.sh 智能入口 + GitHub Actions workflow。

**技术栈：** Docker Compose v2, Bash, Git, GitHub Actions (appleboy/ssh-action)

---

## 文件清单

### 创建的文件

| # | 文件 | 职责 |
|---|------|------|
| 1 | `compose/compose.base.yml` | `name` + 网络定义（proxy_network, backend_network） |
| 2 | `compose/compose.infra.yml` | PostgreSQL 数据库服务 |
| 3 | `compose/compose.gitea.yml` | Gitea + gitea-db-init 服务 |
| 4 | `compose/compose.npm.yml` | Nginx Proxy Manager 服务 |
| 5 | `compose/compose.code-server.yml` | VS Code Server 服务 |
| 6 | `compose/compose.welcome.yml` | 默认欢迎页（nginx） |
| 7 | `scripts/lib.sh` | 共享函数库：路径、日志、compose_cmd 组装、环境加载、Docker 检查 |
| 8 | `scripts/services/gitea.sh` | Gitea 服务更新逻辑 |
| 9 | `scripts/services/npm.sh` | NPM 服务更新逻辑 |
| 10 | `scripts/services/code-server.sh` | Code Server 服务更新逻辑 |
| 11 | `scripts/services/postgres.sh` | PostgreSQL 服务更新逻辑 |
| 12 | `scripts/update-service.sh` | 通用单服务更新入口 |
| 13 | `scripts/update-all.sh` | 全量更新入口 |
| 14 | `scripts/deploy.sh` | 智能部署入口（Git diff 驱动） |
| 15 | `.github/workflows/deploy.yml` | GitHub Actions 触发部署 |
| 16 | `.state/last_deployed_sha` | 初始占位文件 |

### 修改的文件

| # | 文件 | 变更 |
|---|------|------|
| 17 | `scripts/install.sh` | 使用 `compose_cmd()` 替代裸 `docker compose` |
| 18 | `scripts/healthcheck.sh` | 重写：引入 lib.sh、使用 compose_cmd、set -euo pipefail |
| 19 | `scripts/backup.sh` | 使用 `compose_cmd()` 替代裸 `docker compose` |
| 20 | `scripts/restore.sh` | 使用 `compose_cmd()` 替代裸 `docker compose` |
| 21 | `.gitignore` | 添加 `.state/`、`compose/compose.override.yml` |
| 22 | `.env.example` | 更新路径引用（合并后统一处理） |
| 23 | `README.md` | 更新目录结构、部署流程 |

### 删除的文件

| # | 文件 | 理由 |
|---|------|------|
| 24 | `docker-compose.yml` | 被分层 compose 替代 |
| 25 | `scripts/update.sh` | 被 `deploy.sh` + `update-all.sh` 替代 |

---

### 任务 1：创建 compose/compose.base.yml

**文件：**
- 创建：`compose/compose.base.yml`

**内容：** 从现有 `docker-compose.yml` 提取 `name` 和 `networks` 定义。

```yaml
# Docker网络隔离
# proxy_network: 对外服务网络
# backend_network: 数据库内部网络

name: ${COMPOSE_PROJECT_NAME}

networks:
  proxy_network:
    name: proxy_network
    driver: bridge

  backend_network:
    name: backend_network
    driver: bridge
    # 注意：不设 internal: true，否则 Docker 会禁止绑定 127.0.0.1 端口到宿主机
```

- [ ] **步骤 1：** 创建 `compose/` 目录，写入 `compose/compose.base.yml`
- [ ] **步骤 2：** `git add compose/compose.base.yml && git commit -m "feat(compose): add compose.base.yml with network definitions"`

---

### 任务 2：创建 compose/compose.infra.yml

**文件：**
- 创建：`compose/compose.infra.yml`

**内容：** 从现有 `docker-compose.yml` 提取 `postgres` 服务。

```yaml
services:
  # =====================================
  # PostgreSQL 数据库
  # 仅供内部服务及宿主机 127.0.0.1 (SSH) 访问
  # =====================================
  postgres:
    container_name: postgres
    image: postgres:15-bookworm
    restart: unless-stopped

    init: true
    security_opt:
      - "no-new-privileges:true"

    environment:
      TZ: ${TZ}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: postgres

    ports:
      - "127.0.0.1:5432:5432"

    volumes:
      - ./appdata/postgres/data:/var/lib/postgresql/data

    networks:
      - backend_network

    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

    stop_grace_period: 120s
    shm_size: 256m

    deploy:
      resources:
        limits:
          memory: 512M

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

- [ ] **步骤 1：** 写入 `compose/compose.infra.yml`
- [ ] **步骤 2：** `git commit -m "feat(compose): add compose.infra.yml with PostgreSQL service"`

---

### 任务 3：创建 compose/compose.gitea.yml

**文件：**
- 创建：`compose/compose.gitea.yml`

**内容：** 从现有 `docker-compose.yml` 提取 gitea-db-init 和 gitea 服务。

```yaml
services:
  # =====================================
  # Gitea数据库初始化
  # 自动创建独立数据库和用户
  # =====================================
  gitea-db-init:
    container_name: gitea-db-init
    image: postgres:15-bookworm
    restart: "no"
    init: true

    environment:
      TZ: ${TZ}
      PGPASSWORD: ${POSTGRES_PASSWORD}

    networks:
      - backend_network

    command: >
      sh -c "
      echo 'Waiting PostgreSQL...';
      until pg_isready -h postgres -U ${POSTGRES_USER};
      do sleep 2;
      done;
      echo 'Creating Gitea database...';
      psql -h postgres -U ${POSTGRES_USER} \
      -tc \"SELECT 1 FROM pg_database WHERE datname='${GITEA_DB_NAME}'\" \
      | grep -q 1 || \
      psql -h postgres -U ${POSTGRES_USER} \
      -c \"CREATE DATABASE ${GITEA_DB_NAME}\";
      psql -h postgres -U ${POSTGRES_USER} \
      -tc \"SELECT 1 FROM pg_roles WHERE rolname='${GITEA_DB_USER}'\" \
      | grep -q 1 || \
      psql -h postgres -U ${POSTGRES_USER} \
      -c \"CREATE USER ${GITEA_DB_USER} PASSWORD '${GITEA_DB_PASSWORD}'\";
      psql -h postgres -U ${POSTGRES_USER} \
      -c \"GRANT ALL PRIVILEGES ON DATABASE ${GITEA_DB_NAME} TO ${GITEA_DB_USER}\";
      echo 'Gitea database ready';
      "

    depends_on:
      postgres:
        condition: service_healthy

  # =====================================
  # Gitea Git代码托管服务
  # =====================================
  gitea:
    container_name: gitea
    image: gitea/gitea:1.27.0
    restart: unless-stopped

    init: true
    security_opt:
      - "no-new-privileges:true"

    environment:
      TZ: ${TZ}
      GITEA__database__DB_TYPE: postgres
      GITEA__database__HOST: postgres:5432
      GITEA__database__NAME: ${GITEA_DB_NAME}
      GITEA__database__USER: ${GITEA_DB_USER}
      GITEA__database__PASSWD: ${GITEA_DB_PASSWORD}
      GITEA__server__DOMAIN: ${GITEA_DOMAIN}
      GITEA__server__ROOT_URL: https://${GITEA_DOMAIN}
      GITEA__server__SSH_PORT: ${GITEA_SSH_PORT}
      GITEA__server__SSH_LISTEN_PORT: 22
      GITEA__server__HTTP_PORT: 3000
      GITEA_ADMIN_USER: ${GITEA_ADMIN_USER}
      GITEA_ADMIN_PASSWD: ${GITEA_ADMIN_PASSWORD}
      GITEA_ADMIN_EMAIL: ${GITEA_ADMIN_EMAIL}

    ports:
      - "${GITEA_SSH_PORT}:22"

    volumes:
      - ./appdata/gitea:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro

    networks:
      - proxy_network
      - backend_network

    depends_on:
      gitea-db-init:
        condition: service_completed_successfully

    healthcheck:
      test: ["CMD", "wget", "-qO", "/dev/null", "http://localhost:3000/api/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

    stop_grace_period: 60s

    deploy:
      resources:
        limits:
          memory: 512M
```

- [ ] **步骤 1：** 写入 `compose/compose.gitea.yml`
- [ ] **步骤 2：** `git commit -m "feat(compose): add compose.gitea.yml with Gitea services"`

---

### 任务 4：创建 compose/compose.npm.yml

**文件：**
- 创建：`compose/compose.npm.yml`

**内容：** 从现有 `docker-compose.yml` 提取 Nginx Proxy Manager 服务。

```yaml
services:
  # =====================================
  # Nginx Proxy Manager
  # 唯一公网HTTP/HTTPS入口
  # =====================================
  npm:
    container_name: npm
    image: jc21/nginx-proxy-manager:2.15.1
    restart: unless-stopped

    security_opt:
      - "no-new-privileges:true"

    environment:
      TZ: ${TZ}
      CERTBOT_PLUGIN_CLOUDFLARE_VERSION: "5.7.0"

    ports:
      - "${NPM_HTTP_PORT}:80"
      - "${NPM_HTTPS_PORT}:443"
      - "127.0.0.1:${NPM_ADMIN_PORT}:81"

    volumes:
      - ./appdata/npm/data:/data
      - ./appdata/npm/letsencrypt:/etc/letsencrypt

    networks:
      - proxy_network

    healthcheck:
      test: ["CMD", "wget", "-qO", "/dev/null", "http://localhost:81/"]
      interval: 30s
      timeout: 10s
      retries: 3

    deploy:
      resources:
        limits:
          memory: 256M
```

- [ ] **步骤 1：** 写入 `compose/compose.npm.yml`
- [ ] **步骤 2：** `git commit -m "feat(compose): add compose.npm.yml with Nginx Proxy Manager"`

---

### 任务 5：创建 compose/compose.code-server.yml

**文件：**
- 创建：`compose/compose.code-server.yml`

**内容：** 从现有 `docker-compose.yml` 提取 code-server 服务。

```yaml
services:
  # =====================================
  # Web版VS Code
  # =====================================
  code-server:
    container_name: code-server
    image: codercom/code-server:4.129.0
    restart: unless-stopped

    init: true
    security_opt:
      - "no-new-privileges:true"

    environment:
      TZ: ${TZ}
      PASSWORD: ${CODE_SERVER_PASSWORD}

    user: "1000:1000"

    volumes:
      - ./appdata/code-server/config:/home/coder/.config
      - ./data/workspace:/home/coder/project

    networks:
      - proxy_network

    healthcheck:
      test: ["CMD", "wget", "-qO", "/dev/null", "http://localhost:8080/"]
      interval: 30s
      timeout: 10s
      retries: 3

    deploy:
      resources:
        limits:
          memory: 512M
```

- [ ] **步骤 1：** 写入 `compose/compose.code-server.yml`
- [ ] **步骤 2：** `git commit -m "feat(compose): add compose.code-server.yml with VS Code Server"`

---

### 任务 6：创建 compose/compose.welcome.yml

**文件：**
- 创建：`compose/compose.welcome.yml`

**内容：** 从现有 `docker-compose.yml` 提取 welcome 服务。

```yaml
services:
  # =====================================
  # 默认欢迎页
  # =====================================
  welcome:
    container_name: welcome
    image: nginx:stable-alpine
    restart: unless-stopped

    init: true
    security_opt:
      - "no-new-privileges:true"

    read_only: true

    tmpfs:
      - /var/run:uid=101,gid=101
      - /var/cache/nginx:uid=101,gid=101
      - /tmp

    volumes:
      - ./welcome/index.html:/usr/share/nginx/html/index.html:ro

    networks:
      - proxy_network

    deploy:
      resources:
        limits:
          memory: 64M
```

- [ ] **步骤 1：** 写入 `compose/compose.welcome.yml`
- [ ] **步骤 2：** `git commit -m "feat(compose): add compose.welcome.yml with welcome page"`

---

### 任务 7：创建 scripts/lib.sh

**文件：**
- 创建：`scripts/lib.sh`

**内容：** 共享函数库，所有脚本 source 此文件。

```bash
#!/bin/bash
#
# =========================================================
# Docker Server Stack — 共享函数库
#
# 所有脚本通过 source 加载此文件：
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "$SCRIPT_DIR/lib.sh"
#
# =========================================================

# =========================================================
# 路径
# =========================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$PROJECT_DIR/.state"
COMPOSE_DIR="$PROJECT_DIR/compose"

# Compose 文件列表（按顺序）
COMPOSE_FILES=(
  "$COMPOSE_DIR/compose.base.yml"
  "$COMPOSE_DIR/compose.infra.yml"
  "$COMPOSE_DIR/compose.gitea.yml"
  "$COMPOSE_DIR/compose.npm.yml"
  "$COMPOSE_DIR/compose.code-server.yml"
  "$COMPOSE_DIR/compose.welcome.yml"
)

# 如果存在 override 文件则追加
if [ -f "$COMPOSE_DIR/compose.override.yml" ]; then
  COMPOSE_FILES+=("$COMPOSE_DIR/compose.override.yml")
fi

# =========================================================
# compose 命令组装
# =========================================================

compose_cmd() {
  local args=()
  for f in "${COMPOSE_FILES[@]}"; do
    args+=(-f "$f")
  done
  printf "docker compose %s" "${args[*]}"
}

compose() {
  local args=()
  for f in "${COMPOSE_FILES[@]}"; do
    args+=(-f "$f")
  done
  command docker compose "${args[@]}" "$@"
}

# =========================================================
# 颜色与日志
# =========================================================

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

log()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
info()   { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()  { echo -e "${RED}[ERROR]${RESET} $*"; }

# =========================================================
# 环境变量
# =========================================================

load_env() {
  local env_file="$PROJECT_DIR/.env"
  if [ ! -f "$env_file" ]; then
    error ".env not found at $env_file"
    exit 1
  fi
  set -a
  source "$env_file"
  set +a
  info "Environment loaded"
}

# =========================================================
# Docker 检查
# =========================================================

check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    error "Docker not installed"
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    error "Docker daemon not running"
    exit 1
  fi
  info "Docker OK"
}

check_compose() {
  if ! docker compose version >/dev/null 2>&1; then
    error "docker compose plugin not available"
    exit 1
  fi
  info "Docker Compose OK"
}
```

- [ ] **步骤 1：** 创建 `scripts/lib.sh`
- [ ] **步骤 2：** `chmod +x scripts/lib.sh`
- [ ] **步骤 3：** `git add scripts/lib.sh && git commit -m "feat(scripts): add shared library lib.sh"`

---

### 任务 8：创建服务映射脚本

**文件：**
- 创建：`scripts/services/gitea.sh`
- 创建：`scripts/services/npm.sh`
- 创建：`scripts/services/code-server.sh`
- 创建：`scripts/services/postgres.sh`

**内容：** 每个脚本定义 `update()` 函数，供 `update-service.sh` 调用。

```bash
# scripts/services/gitea.sh
update() {
  log "Updating Gitea..."
  compose pull gitea
  compose up -d --no-deps gitea
  # 健康检查
  local i
  for i in $(seq 1 12); do
    if docker exec gitea wget -qO- http://localhost:3000/api/health >/dev/null 2>&1; then
      info "Gitea health check passed"
      return 0
    fi
    sleep 5
  done
  error "Gitea health check failed"
  return 1
}
```

```bash
# scripts/services/npm.sh
update() {
  log "Updating Nginx Proxy Manager..."
  compose pull npm
  compose up -d --no-deps npm
  local i
  for i in $(seq 1 12); do
    if docker exec npm wget -qO- http://localhost:81/ >/dev/null 2>&1; then
      info "NPM health check passed"
      return 0
    fi
    sleep 5
  done
  error "NPM health check failed"
  return 1
}
```

```bash
# scripts/services/code-server.sh
update() {
  log "Updating Code Server..."
  compose pull code-server
  compose up -d --no-deps code-server
  local i
  for i in $(seq 1 12); do
    if docker exec code-server wget -qO- http://localhost:8080/ >/dev/null 2>&1; then
      info "Code Server health check passed"
      return 0
    fi
    sleep 5
  done
  error "Code Server health check failed"
  return 1
}
```

```bash
# scripts/services/postgres.sh
update() {
  log "Updating PostgreSQL..."
  compose pull postgres
  compose up -d --no-deps postgres
  local i
  for i in $(seq 1 12); do
    if docker exec postgres pg_isready -U "${POSTGRES_USER}" >/dev/null 2>&1; then
      info "PostgreSQL health check passed"
      return 0
    fi
    sleep 5
  done
  error "PostgreSQL health check failed"
  return 1
}
```

- [ ] **步骤 1：** 创建 `scripts/services/` 目录
- [ ] **步骤 2：** 写入 4 个 service 脚本
- [ ] **步骤 3：** `chmod +x scripts/services/*.sh`
- [ ] **步骤 4：** `git add scripts/services/ && git commit -m "feat(scripts): add per-service update scripts"`

---

### 任务 9：创建 scripts/update-service.sh

**文件：**
- 创建：`scripts/update-service.sh`

**内容：** 单服务更新入口，source 对应 service 脚本并调用其 `update()` 函数。

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  echo "Usage: $0 <service-name>"
  echo ""
  echo "Services: gitea, npm, code-server, postgres"
  exit 1
}

SERVICE="${1:-}"
[ -n "$SERVICE" ] || usage

SERVICE_SCRIPT="$SCRIPT_DIR/services/${SERVICE}.sh"
if [ ! -f "$SERVICE_SCRIPT" ]; then
  error "Unknown service: $SERVICE"
  error "No script found at $SERVICE_SCRIPT"
  exit 1
fi

load_env
check_docker

log "========================================="
log "Updating service: $SERVICE"
log "========================================="

source "$SERVICE_SCRIPT"
update

log "Cleaning unused images..."
docker image prune -f

log "Service $SERVICE update completed"
```

- [ ] **步骤 1：** 写入 `scripts/update-service.sh`
- [ ] **步骤 2：** `chmod +x scripts/update-service.sh`
- [ ] **步骤 3：** `git add scripts/update-service.sh && git commit -m "feat(scripts): add update-service.sh for single service updates"`

---

### 任务 10：创建 scripts/update-all.sh

**文件：**
- 创建：`scripts/update-all.sh`

**内容：** 全量更新：pull 所有镜像、重建所有服务、健康检查概览、清理。

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

load_env
check_docker

log "========================================="
log "Full update — all services"
log "========================================="

log "Pulling all images..."
compose pull

log "Recreating all services..."
compose up -d --remove-orphans

log "Waiting for services to be healthy..."
sleep 15
compose ps

log "Cleaning unused images..."
docker image prune -f

log "========================================="
log "Full update completed"
log "========================================="
```

- [ ] **步骤 1：** 写入 `scripts/update-all.sh`
- [ ] **步骤 2：** `chmod +x scripts/update-all.sh`
- [ ] **步骤 3：** `git add scripts/update-all.sh && git commit -m "feat(scripts): add update-all.sh for full redeployment"`

---

### 任务 11：创建 scripts/deploy.sh

**文件：**
- 创建：`scripts/deploy.sh`

**内容：** 智能部署入口，通过 Git diff 判断变更范围，执行对应更新策略。

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

load_env
check_docker

log "========================================="
log "Smart Deploy"
log "========================================="

cd "$PROJECT_DIR"

# --------------------------------------------------
# 1. 获取 SHA
# --------------------------------------------------

CURRENT_SHA=$(git rev-parse HEAD)
LAST_SHA_FILE="$STATE_DIR/last_deployed_sha"

if [ -f "$LAST_SHA_FILE" ]; then
  LAST_SHA=$(cat "$LAST_SHA_FILE")
else
  # 首次部署：从头 diff
  LAST_SHA=$(git rev-list --max-parents=0 HEAD)
  log "First deploy — comparing against initial commit"
fi

log "Current SHA : $CURRENT_SHA"
log "Last SHA   : $LAST_SHA"

# 如果 SHA 相同则跳过
if [ "$CURRENT_SHA" = "$LAST_SHA" ]; then
  info "No new commits since last deploy, skipping"
  exit 0
fi

# --------------------------------------------------
# 2. 获取变更文件列表
# --------------------------------------------------

CHANGED=$(git diff --name-only "$LAST_SHA".."$CURRENT_SHA" 2>/dev/null || git diff --name-only "$LAST_SHA".."$CURRENT_SHA" -- 2>/dev/null || true)

if [ -z "$CHANGED" ]; then
  info "No file changes detected, skipping"
  exit 0
fi

log "Changed files:"
echo "$CHANGED" | while IFS= read -r f; do echo "  $f"; done

# --------------------------------------------------
# 3. 判断是否仅文档变更
# --------------------------------------------------

ONLY_DOCS=true
while IFS= read -r f; do
  case "$f" in
    *.md|*.txt|*.gitignore|*.mdx) ;;
    *) ONLY_DOCS=false; break ;;
  esac
done <<< "$CHANGED"

if $ONLY_DOCS; then
  info "Only documentation changed, skipping deployment"
  echo "$CURRENT_SHA" > "$LAST_SHA_FILE"
  exit 0
fi

# --------------------------------------------------
# 4. 检查全局配置变更
# --------------------------------------------------

GLOBAL_CHANGE=false
while IFS= read -r f; do
  case "$f" in
    .env|compose/compose.base.yml|compose/compose.override.yml)
      GLOBAL_CHANGE=true; break ;;
  esac
done <<< "$CHANGED"

if $GLOBAL_CHANGE; then
  log "Global configuration changed — full deploy"
  ./scripts/update-all.sh
  echo "$CURRENT_SHA" > "$LAST_SHA_FILE"
  info "Deploy completed (full)"
  exit 0
fi

# --------------------------------------------------
# 5. 逐服务映射
# --------------------------------------------------

# 收集需要更新的服务
SERVICES=()

while IFS= read -r f; do
  case "$f" in
    compose/compose.infra.yml|scripts/services/postgres.sh)
      SERVICES+=("postgres") ;;
    compose/compose.gitea.yml|scripts/services/gitea.sh)
      SERVICES+=("gitea") ;;
    compose/compose.npm.yml|scripts/services/npm.sh)
      SERVICES+=("npm") ;;
    compose/compose.code-server.yml|scripts/services/code-server.sh)
      SERVICES+=("code-server") ;;
    compose/compose.welcome.yml)
      SERVICES+=("welcome") ;;
  esac
done <<< "$CHANGED"

# 去重
UNIQUE_SERVICES=()
while IFS= read -r s; do
  found=false
  for u in "${UNIQUE_SERVICES[@]}"; do
    [ "$u" = "$s" ] && found=true && break
  done
  $found || UNIQUE_SERVICES+=("$s")
done < <(printf "%s\n" "${SERVICES[@]}")

# --------------------------------------------------
# 6. 执行更新
# --------------------------------------------------

if [ ${#UNIQUE_SERVICES[@]} -eq 0 ]; then
  # 有文件变更但没匹配到服务映射 —— 全量部署做兜底
  log "Changes detected but no specific service match — full deploy"
  ./scripts/update-all.sh
elif [ ${#UNIQUE_SERVICES[@]} -eq 1 ]; then
  log "Updating single service: ${UNIQUE_SERVICES[0]}"
  ./scripts/update-service.sh "${UNIQUE_SERVICES[0]}"
else
  log "Multiple services changed (${UNIQUE_SERVICES[*]}) — full deploy"
  ./scripts/update-all.sh
fi

# --------------------------------------------------
# 7. 保存 SHA
# --------------------------------------------------

echo "$CURRENT_SHA" > "$LAST_SHA_FILE"
info "Deploy completed"
```

- [ ] **步骤 1：** 写入 `scripts/deploy.sh`
- [ ] **步骤 2：** `chmod +x scripts/deploy.sh`
- [ ] **步骤 3：** `git add scripts/deploy.sh && git commit -m "feat(scripts): add deploy.sh with smart diff-based deployment"`

---

### 任务 12：更新 .gitignore

**文件：**
- 修改：`.gitignore`

**内容：** 添加 `.state/` 和 `compose/compose.override.yml`。

```
# 新增：
.state/
compose/compose.override.yml
```

- [ ] **步骤 1：** 在 `.gitignore` 末尾追加上述两行
- [ ] **步骤 2：** `git add .gitignore && git commit -m "chore: add .state and compose.override.yml to gitignore"`

---

### 任务 13：更新 scripts/install.sh

**文件：**
- 修改：`scripts/install.sh`

**内容：** 将 `docker compose` 替换为 `compose` 函数调用（需要先 source lib.sh）。注意：install.sh 有自己的路径计算逻辑，需要改用 lib.sh 提供的函数。

关键变更点：
1. 在文件头部 source lib.sh
2. 替换 `docker compose` → `compose`
3. 更新目录创建路径（如果有变更）
4. 使用 `log()` 函数（lib.sh 已提供）

```bash
# 文件头部改为：
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# 移除原有的 log() 函数定义（lib.sh 已提供）

# 替换所有 docker compose → compose
```

- [ ] **步骤 1：** 修改 `scripts/install.sh` — 引入 lib.sh，替换 compose 调用
- [ ] **步骤 2：** 验证：`grep -c 'docker compose' scripts/install.sh` 应返回 0（全部替换）
- [ ] **步骤 3：** `git add scripts/install.sh && git commit -m "refactor(scripts): update install.sh to use lib.sh and layered compose"`

---

### 任务 14：重写 scripts/healthcheck.sh

**文件：**
- 修改：`scripts/healthcheck.sh`

**内容：** 完整重写，引入 lib.sh，使用 `compose` 函数替代裸 `docker compose`，使用 `set -euo pipefail`。

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

load_env

FAILED=0

check_docker() {
  if docker info >/dev/null 2>&1; then
    info "Docker service running"
  else
    error "Docker service unavailable"
    FAILED=1
  fi
}

check_containers() {
  echo ""
  echo "--------------------------------"
  echo "Container Status"
  echo "--------------------------------"
  compose ps
  local unhealthy
  unhealthy=$(compose ps --format json | grep -i unhealthy || true)
  if [ -n "$unhealthy" ]; then
    error "Some containers are unhealthy"
    FAILED=1
  else
    info "Container health status OK"
  fi
}

check_postgres() {
  echo ""
  echo "--------------------------------"
  echo "PostgreSQL"
  echo "--------------------------------"
  if docker exec postgres pg_isready -U "${POSTGRES_USER}" >/dev/null 2>&1; then
    info "PostgreSQL ready"
  else
    error "PostgreSQL unavailable"
    FAILED=1
  fi
}

check_gitea() {
  echo ""
  echo "--------------------------------"
  echo "Gitea"
  echo "--------------------------------"
  if docker exec gitea wget -qO- http://localhost:3000/api/health >/dev/null 2>&1; then
    info "Gitea HTTP OK"
  else
    error "Gitea HTTP failed"
    FAILED=1
  fi
}

check_npm() {
  echo ""
  echo "--------------------------------"
  echo "Nginx Proxy Manager"
  echo "--------------------------------"
  if docker exec npm wget -qO- http://localhost:81/ >/dev/null 2>&1; then
    info "NPM running"
  else
    error "NPM unavailable"
    FAILED=1
  fi
}

check_disk() {
  echo ""
  echo "--------------------------------"
  echo "Disk Usage"
  echo "--------------------------------"
  df -h "$PROJECT_DIR"
  local usage
  usage=$(df "$PROJECT_DIR" | awk 'NR==2 {print $5}' | tr -d '%')
  if [ "$usage" -ge 90 ]; then
    warn "Disk usage above 90%"
  else
    info "Disk usage normal"
  fi
}

check_memory() {
  echo ""
  echo "--------------------------------"
  echo "Memory"
  echo "--------------------------------"
  free -h
}

main() {
  echo ""
  echo "================================="
  echo " Docker Stack Health Check"
  echo "================================="

  check_docker
  check_containers
  check_postgres
  check_gitea
  check_npm
  check_disk
  check_memory

  echo ""
  echo "================================="
  if [ "$FAILED" -eq 0 ]; then
    info "ALL CHECKS PASSED"
    exit 0
  else
    error "HEALTH CHECK FAILED"
    exit 1
  fi
}

main "$@"
```

- [ ] **步骤 1：** 重写 `scripts/healthcheck.sh`
- [ ] **步骤 2：** `chmod +x scripts/healthcheck.sh`
- [ ] **步骤 3：** `git add scripts/healthcheck.sh && git commit -m "refactor(scripts): rewrite healthcheck.sh with lib.sh and layered compose"`

---

### 任务 15：更新 scripts/backup.sh

**文件：**
- 修改：`scripts/backup.sh`

**内容：** 引入 lib.sh，替换 `docker compose` 调用为 `compose` 函数。

注意：backup.sh 的 `docker exec postgres` 和 `docker exec gitea` 不需要改 — 只有 `docker compose` 调用的地方要替换。

搜索 backcup.sh 中所有 `docker compose` 的出现并替换为 `compose`。

- [ ] **步骤 1：** 在 `scripts/backup.sh` 头部引入 lib.sh，替换所有 `docker compose` 为 `compose`，移除重复的 log() 定义
- [ ] **步骤 2：** `git add scripts/backup.sh && git commit -m "refactor(scripts): update backup.sh to use lib.sh"`

---

### 任务 16：更新 scripts/restore.sh

**文件：**
- 修改：`scripts/restore.sh`

**内容：** 引入 lib.sh，替换 `docker compose` 调用为 `compose` 函数。

- [ ] **步骤 1：** 在 `scripts/restore.sh` 头部引入 lib.sh，替换所有 `docker compose` 为 `compose`，移除重复的 log() 定义
- [ ] **步骤 2：** `git add scripts/restore.sh && git commit -m "refactor(scripts): update restore.sh to use lib.sh"`

---

### 任务 17：删除 docker-compose.yml 和 scripts/update.sh

**文件：**
- 删除：`docker-compose.yml`
- 删除：`scripts/update.sh`

- [ ] **步骤 1：** `git rm docker-compose.yml`
- [ ] **步骤 2：** `git rm scripts/update.sh`
- [ ] **步骤 3：** `git commit -m "chore: remove deprecated docker-compose.yml and update.sh"`

---

### 任务 18：创建 .github/workflows/deploy.yml

**文件：**
- 创建：`.github/workflows/deploy.yml`

**内容：** GitHub Actions workflow — push 到 main 或 workflow_dispatch 触发，SSH 到服务器执行 deploy.sh。

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
        uses: appleboy/ssh-action@v1.2.0
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SERVER_SSH_KEY }}
          port: ${{ secrets.SERVER_PORT || 22 }}
          script: |
            set -e
            cd /data/server
            git pull --ff-only
            chmod +x scripts/*.sh scripts/services/*.sh
            ./scripts/deploy.sh
```

- [ ] **步骤 1：** 创建 `.github/workflows/` 目录，写入 `deploy.yml`
- [ ] **步骤 2：** `git add .github/ && git commit -m "ci: add GitHub Actions deploy workflow"`

---

### 任务 19：更新 .env.example

**文件：**
- 修改：`.env.example`

**内容：** 更新文件中所有指向 `docker-compose.yml` 的注释引用为指向分层 compose 文件。

注意：无法直接读取 `.env.example`（权限限制），使用 `grep` 或 `sed` 查看和修改。

```bash
# 搜索 .env.example 中引用 docker-compose.yml 的行
grep -n 'docker-compose.yml\|compose' .env.example
```

- [ ] **步骤 1：** 搜索 `.env.example` 中的路径引用
- [ ] **步骤 2：** 更新所有引用路径
- [ ] **步骤 3：** `git add .env.example && git commit -m "docs: update .env.example paths for layered compose"`

---

### 任务 20：更新 README.md

**文件：**
- 修改：`README.md`

**内容：** 更新目录结构图、部署流程、脚本使用说明。

主要变更：
1. 目录结构图：更新为新的分层结构
2. 部署流程：增加 GitHub Actions + deploy.sh 的说明
3. 维护章节：去除 update.sh 引用，增加 update-service.sh 和 update-all.sh
4. 增加智能部署说明

- [ ] **步骤 1：** 更新 README.md 中的目录结构
- [ ] **步骤 2：** 更新部署和维护章节
- [ ] **步骤 3：** `git add README.md && git commit -m "docs: update README for layered compose and smart deploy"`

---

### 任务 21：创建 .state/last_deployed_sha 占位

**文件：**
- 创建：`.state/last_deployed_sha`

```bash
# 创建目录和占位文件
mkdir -p .state
# 文件内容为空（首次部署时由 deploy.sh 填充）
touch .state/last_deployed_sha
```

- [ ] **步骤 1：** 创建 `.state/last_deployed_sha`（空文件）
- [ ] **步骤 2：** `git add .state/ && git commit -m "chore: add .state directory for deploy tracking"`
