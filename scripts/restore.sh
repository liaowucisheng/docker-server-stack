#!/bin/bash

# =========================================================
# Docker Self-hosted Server Restore Script
#
# 功能:
#   1. 恢复 PostgreSQL 数据库
#   2. 恢复 Gitea 数据
#
# 对应:
#   backup.sh
#
#
# 使用:
#
#   ./restore.sh postgres 文件名
#
#   ./restore.sh gitea 文件名
#
#
# 示例:
#
#   ./restore.sh postgres gitea_20260723_030000.sql.gz
#
#   ./restore.sh gitea gitea-dump-20260723_030000.zip
#
#
# 注意:
#   恢复会覆盖现有数据
#
# =========================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

BACKUP_DIR="$PROJECT_DIR/data/backup"

load_env

# =========================================================
# 使用说明
# =========================================================

usage() {

    cat << EOF

Usage:

  $0 <type> <backup_file>

Types:

  postgres
      Restore PostgreSQL database

  gitea
      Restore Gitea dump

Examples:

  Restore PostgreSQL:

  $0 postgres gitea_20260723_030000.sql.gz

  Restore Gitea:

  $0 gitea gitea-dump-20260723_030000.zip

EOF

    exit 1

}

# =========================================================
# Docker检查
# =========================================================

check_environment() {

    if ! docker info > /dev/null 2>&1; then

        log "ERROR: Docker is not running"

        exit 1

    fi

    if ! docker ps \
        --format '{{.Names}}' \
        | grep -q "^postgres$"; then

        log "ERROR: postgres container not running"

        exit 1

    fi

}

# =========================================================
# 安全确认
# =========================================================

confirm() {

    read -rp "
WARNING:
This operation will overwrite current data.

Continue? (yes/no): " answer

    if [ "$answer" != "yes" ]; then

        echo "Cancelled"

        exit 0

    fi

}

# =========================================================
# PostgreSQL恢复
# =========================================================

restore_postgres() {

    local file="$1"

    local backup_file="$BACKUP_DIR/postgres/$file"

    if [ ! -f "$backup_file" ]; then

        log "Backup file not found:"
        echo "$backup_file"

        exit 1

    fi

    confirm

    log "Stopping application containers..."

    compose stop gitea

    log "Restoring PostgreSQL..."

    gunzip -c "$backup_file" \
        | docker exec -i postgres \
            psql \
            -U "$POSTGRES_USER" \
            postgres

    log "PostgreSQL restore completed"

    compose start gitea

    log "Gitea restarted"

}

# =========================================================
# Gitea恢复
# =========================================================

restore_gitea() {

    local file="$1"

    local backup_file="$BACKUP_DIR/gitea/$file"

    if [ ! -f "$backup_file" ]; then

        log "Backup file not found:"
        echo "$backup_file"

        exit 1

    fi

    confirm

    log "Stopping Gitea..."

    compose stop gitea

    log "Copy backup into container..."

    docker cp \
        "$backup_file" \
        gitea:/tmp/restore.zip

    log "Restoring Gitea..."

    docker exec gitea \
        gitea restore \
        --from /tmp/restore.zip

    log "Cleaning temporary file"

    docker exec gitea \
        rm -f /tmp/restore.zip

    log "Gitea restore completed"

    compose start gitea

    log "Gitea restarted"

}

# =========================================================
# Vaultwarden恢复
# =========================================================

restore_vaultwarden() {
    local file="$1"
    local backup_file="$BACKUP_DIR/vaultwarden/$file"
    local data_dir="$PROJECT_DIR/appdata/vaultwarden"

    if [ ! -f "$backup_file" ]; then
        log "Backup file not found:"
        echo "$backup_file"
        exit 1
    fi

    confirm

    log "Stopping Vaultwarden..."
    compose stop vaultwarden || true

    log "Backing up current data (safety)..."
    if [ -d "$data_dir" ]; then
        local safety_backup="$data_dir.bak.$(date +%Y%m%d_%H%M%S)"
        mv "$data_dir" "$safety_backup"
        log "Current data moved to $safety_backup"
    fi

    log "Restoring Vaultwarden data..."
    mkdir -p "$PROJECT_DIR/appdata"
    tar -xzf "$backup_file" -C "$PROJECT_DIR/appdata"

    # 确保权限正确（vaultwarden 容器默认用 UID 1000 或 root，视镜像而定）
    # 大多数情况下不需要改，若启动失败可手动 chown

    log "Starting Vaultwarden..."
    compose start vaultwarden

    log "Vaultwarden restore completed"
    log "Please verify: https://${VAULTWARDEN_DOMAIN}"
}

# =========================================================
# 主程序
# =========================================================

main() {

    [ $# -eq 2 ] || usage

    TYPE="$1"

    FILE="$2"

    check_environment

    case "$TYPE" in
        postgres)
            restore_postgres "$FILE"
            ;;
        gitea)
            restore_gitea "$FILE"
            ;;
        vaultwarden)
            restore_vaultwarden "$FILE"
            ;;
        *)
            usage
            ;;
    esac

    log "Restore finished"

}

main "$@"
