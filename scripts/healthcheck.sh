#!/bin/bash

# =========================================================
# Docker Self-hosted Server Health Check Script
#
# 功能:
#
#   检查 Docker Compose 服务运行状态
#
# 检查:
#
#   - Docker状态
#   - Container状态
#   - Healthcheck状态
#   - PostgreSQL
#   - Gitea
#   - Nginx Proxy Manager
#   - 磁盘空间
#   - 内存
#
#
# 使用:
#
#   ./scripts/healthcheck.sh
#
#
# 返回:
#
#   0   全部正常
#   1   存在异常
#
# =========================================================

set -uo pipefail

# =========================================================
# 路径
# =========================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# =========================================================
# 加载环境
# =========================================================

ENV_FILE="$PROJECT_DIR/.env"

if [ -f "$ENV_FILE" ]

then

    set -a
    source "$ENV_FILE"
    set +a

fi

# =========================================================
# 颜色
# =========================================================

RED="\033[31m"

GREEN="\033[32m"

YELLOW="\033[33m"

RESET="\033[0m"

# =========================================================
# 日志
# =========================================================

info()
{
    echo -e "${GREEN}[OK]${RESET} $*"
}

warn()
{
    echo -e "${YELLOW}[WARN]${RESET} $*"
}

error()
{
    echo -e "${RED}[ERROR]${RESET} $*"
}

FAILED=0

# =========================================================
# Docker检查
# =========================================================

check_docker()
{

if docker info >/dev/null 2>&1

then

    info "Docker service running"

else

    error "Docker service unavailable"

    FAILED=1

fi

}

# =========================================================
# Compose检查
# =========================================================

check_compose()
{

cd "$PROJECT_DIR"

if docker compose ps >/dev/null 2>&1

then

    info "Docker Compose available"

else

    error "Docker Compose unavailable"

    FAILED=1

fi

}

# =========================================================
# 容器状态
# =========================================================

check_containers()
{

cd "$PROJECT_DIR"

echo

echo "--------------------------------"

echo "Container Status"

echo "--------------------------------"

docker compose ps

local unhealthy

unhealthy=$(

docker compose ps \
--format json \
| grep -i unhealthy || true

)

if [ -n "$unhealthy" ]

then

    error "Some containers are unhealthy"

    FAILED=1

else

    info "Container health status OK"

fi

}

# =========================================================
# PostgreSQL检查
# =========================================================

check_postgres()
{

echo

echo "--------------------------------"

echo "PostgreSQL"

echo "--------------------------------"

if docker exec postgres \
pg_isready \
-U "$POSTGRES_USER" \
>/dev/null 2>&1

then

    info "PostgreSQL ready"

else

    error "PostgreSQL unavailable"

    FAILED=1

fi

}

# =========================================================
# Gitea检查
# =========================================================

check_gitea()
{

echo

echo "--------------------------------"

echo "Gitea"

echo "--------------------------------"

if docker exec gitea \
wget \
-qO- \
http://localhost:3000/api/health \
>/dev/null 2>&1

then

    info "Gitea HTTP OK"

else

    error "Gitea HTTP failed"

    FAILED=1

fi

}

# =========================================================
# NPM检查
# =========================================================

check_npm()
{

echo

echo "--------------------------------"

echo "Nginx Proxy Manager"

echo "--------------------------------"

if docker exec npm \
wget \
-qO- \
http://localhost:81/ \
>/dev/null 2>&1

then

    info "NPM running"

else

    error "NPM unavailable"

    FAILED=1

fi

}

# =========================================================
# 磁盘检查
# =========================================================

check_disk()
{

echo

echo "--------------------------------"

echo "Disk Usage"

echo "--------------------------------"

df -h "$PROJECT_DIR"

usage=$(

df "$PROJECT_DIR" \
| awk 'NR==2 {print $5}' \
| tr -d '%'

)

if [ "$usage" -ge 90 ]

then

    warn "Disk usage above 90%"

else

    info "Disk usage normal"

fi

}

# =========================================================
# 内存检查
# =========================================================

check_memory()
{

echo

echo "--------------------------------"

echo "Memory"

echo "--------------------------------"

free -h

}

# =========================================================
# 主程序
# =========================================================

main()
{

echo

echo "================================="

echo " Docker Stack Health Check"

echo "================================="

check_docker

check_compose

check_containers

check_postgres

check_gitea

check_npm

check_disk

check_memory

echo

echo "================================="

if [ "$FAILED" -eq 0 ]

then

    info "ALL CHECKS PASSED"

    exit 0

else

    error "HEALTH CHECK FAILED"

    exit 1

fi

}

main "$@"