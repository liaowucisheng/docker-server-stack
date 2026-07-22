#!/bin/bash

# =========================================================
# Docker Self-hosted Server Update Script
#
# 功能:
#
#   1. 更新 Git 仓库代码
#   2. 拉取最新 Docker 镜像
#   3. 重建并启动服务
#   4. 清理旧镜像
#
#
# 使用:
#
#   更新全部:
#
#       ./scripts/update.sh
#
#
#   更新单个服务:
#
#       ./scripts/update.sh gitea
#
#
# 示例:
#
#       ./scripts/update.sh npm
#
#
# =========================================================

set -euo pipefail

# =========================================================
# 路径
# =========================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# =========================================================
# 加载环境变量
# =========================================================

ENV_FILE="$PROJECT_DIR/.env"

if [ -f "$ENV_FILE" ]

then

    set -a
    source "$ENV_FILE"
    set +a

else

    echo "ERROR: .env not found"

    exit 1

fi

# =========================================================
# 日志
# =========================================================

log()
{

echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"

}

# =========================================================
# 检查环境
# =========================================================

check_environment()
{

if ! docker info >/dev/null 2>&1

then

    log "ERROR: Docker is not running"

    exit 1

fi

if ! docker compose version >/dev/null 2>&1

then

    log "ERROR: docker compose not available"

    exit 1

fi

}

# =========================================================
# Git更新
# =========================================================

update_git()
{

cd "$PROJECT_DIR"

if [ ! -d ".git" ]

then

    log "Not a git repository, skip git update"

    return

fi

log "Checking git status..."

if [ -n "$(git status --porcelain)" ]

then

    log "WARNING: Local changes detected"

    git status --short

    read -rp \
    "Continue update? (yes/no): " answer

    if [ "$answer" != "yes" ]

    then

        exit 0

    fi

fi

log "Pulling latest code..."

git pull

}

# =========================================================
# 更新Docker镜像
# =========================================================

pull_images()
{

cd "$PROJECT_DIR"

if [ $# -eq 1 ]

then

    SERVICE="$1"

    log "Pulling image: $SERVICE"

    docker compose pull "$SERVICE"

else

    log "Pulling all images"

    docker compose pull

fi

}

# =========================================================
# 重建服务
# =========================================================

recreate_services()
{

cd "$PROJECT_DIR"

if [ $# -eq 1 ]

then

    SERVICE="$1"

    log "Updating service: $SERVICE"

    docker compose up -d \
        --remove-orphans \
        "$SERVICE"

else

    log "Updating all services"

    docker compose up -d \
        --remove-orphans

fi

}

# =========================================================
# 清理旧镜像
# =========================================================

cleanup()
{

log "Cleaning unused Docker images..."

docker image prune -f

}

# =========================================================
# 状态检查
# =========================================================

show_status()
{

cd "$PROJECT_DIR"

echo

log "Current container status"

docker compose ps

}

# =========================================================
# 主流程
# =========================================================

main()
{

SERVICE="${1:-}"

check_environment

log "================================"

log "Docker Stack Update Started"

log "================================"

#
# 更新前提示
#

echo

echo "Before update:"
echo "  Recommended:"
echo "  ./scripts/backup.sh"

echo

read -rp \
"Continue update? (yes/no): " confirm

if [ "$confirm" != "yes" ]

then

    log "Cancelled"

    exit 0

fi

update_git

pull_images "$SERVICE"

recreate_services "$SERVICE"

cleanup

show_status

log "================================"

log "Update completed"

log "================================"

}

main "$@"