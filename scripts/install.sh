#!/bin/bash

# =========================================================
# Docker Self-hosted Server Install Script
#
# 功能:
#
#   首次部署 Docker Compose 服务
#
# 包含:
#
#   1. 环境检查
#   2. 创建目录
#   3. 检查配置
#   4. 设置权限
#   5. 拉取镜像
#   6. 启动服务
#   7. 初始化检查
#
#
# 使用:
#
#   ./scripts/install.sh
#
#
# 适用:
#
#   Ubuntu Server
#   Docker Compose v2
#
# =========================================================

set -euo pipefail

# =========================================================
# 路径
# =========================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# =========================================================
# 日志
# =========================================================

log()
{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# =========================================================
# 检查root权限
# =========================================================

check_root()
{

if [ "$EUID" -ne 0 ]

then

    log "WARNING: recommended running as root"

fi

}

# =========================================================
# 检查Docker
# =========================================================

check_docker()
{

log "Checking Docker..."

if ! command -v docker >/dev/null 2>&1

then

    log "ERROR: Docker not installed"

    echo

    echo "Install Docker first:"
    echo "https://docs.docker.com/engine/install/"

    exit 1

fi

if ! docker info >/dev/null 2>&1

then

    log "ERROR: Docker service not running"

    exit 1

fi

log "Docker OK"

}

# =========================================================
# 检查Compose
# =========================================================

check_compose()
{

if ! docker compose version >/dev/null 2>&1

then

    log "ERROR: Docker Compose plugin missing"

    exit 1

fi

log "Docker Compose OK"

}

# =========================================================
# 检查环境文件
# =========================================================

check_env()
{

cd "$PROJECT_DIR"

if [ ! -f ".env" ]

then

    echo

    log "ERROR: .env not found"

    echo

    echo "Create from template:"

    echo

    echo "cp .env.example .env"

    echo

    exit 1

fi

log ".env found"

}

# =========================================================
# 创建目录
# =========================================================

create_directories()
{

log "Creating directories..."

mkdir -p \

"$PROJECT_DIR/appdata/postgres/data" \

"$PROJECT_DIR/appdata/gitea" \

"$PROJECT_DIR/appdata/npm/data" \

"$PROJECT_DIR/appdata/npm/letsencrypt" \

"$PROJECT_DIR/appdata/code-server/config" \

"$PROJECT_DIR/data/workspace" \

"$PROJECT_DIR/data/backup/postgres" \

"$PROJECT_DIR/data/backup/gitea"

# welcome目录

mkdir -p "$PROJECT_DIR/welcome"

log "Directory creation completed"

}

# =========================================================
# 检查welcome页面
# =========================================================

check_welcome()
{

if [ ! -f "$PROJECT_DIR/welcome/index.html" ]

then

cat > "$PROJECT_DIR/welcome/index.html" <<EOF

<!DOCTYPE html>

<html>

<head>

<meta charset="utf-8">

<title>Welcome</title>

</head>

<body>

<h1>Docker Server Stack</h1>

<p>Your server is running.</p>

</body>

</html>

EOF

log "Created default welcome page"

fi

}

# =========================================================
# 设置脚本权限
# =========================================================

permission()
{

log "Setting script permissions..."

chmod +x "$PROJECT_DIR/scripts/"*.sh

}

# =========================================================
# Docker启动
# =========================================================

start_services()
{

cd "$PROJECT_DIR"

log "Pulling Docker images..."

docker compose pull

log "Starting services..."

docker compose up -d

}

# =========================================================
# 等待服务
# =========================================================

wait_services()
{

log "Waiting containers startup..."

sleep 20

docker compose ps

}

# =========================================================
# 主程序
# =========================================================

main()
{

echo

echo "================================="

echo " Docker Server Installation"

echo "================================="

echo

check_root

check_docker

check_compose

check_env

create_directories

check_welcome

permission

start_services

wait_services

echo

log "Installation completed"

echo

echo "Next steps:"

echo

echo "1. Check status:"

echo "   ./scripts/healthcheck.sh"

echo

echo "2. Open NPM:"

echo "   http://server-ip:81"

echo

echo "3. Configure domain proxy"

echo

}

main "$@"