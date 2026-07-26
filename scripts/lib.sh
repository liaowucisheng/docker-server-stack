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
# compose 命令
# =========================================================

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

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
info() { echo -e "${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*"; }

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
    if ! command -v docker > /dev/null 2>&1; then
        error "Docker not installed"
        exit 1
    fi
    if ! docker info > /dev/null 2>&1; then
        error "Docker daemon not running"
        exit 1
    fi
    info "Docker OK"
}

check_compose() {
    if ! docker compose version > /dev/null 2>&1; then
        error "docker compose plugin not available"
        exit 1
    fi
    info "Docker Compose OK"
}
