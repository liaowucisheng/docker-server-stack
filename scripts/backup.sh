#!/bin/bash

# =========================================================
# Docker Self-hosted Server Stack Backup Script
#
# Backup:
#   1. PostgreSQL databases
#   2. Gitea repositories and configuration
#   3. Vaultwarden data
#
# Directory:
#   /data/server
#
# Usage:
#   chmod +x scripts/backup.sh
#   ./scripts/backup.sh
#
# =========================================================

# 遇到错误立即退出
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

BACKUP_DIR="$PROJECT_DIR/data/backup"

# 时间标签
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 保留多少天备份
RETENTION_DAYS=30

# =========================================================
# PostgreSQL备份
# =========================================================

backup_postgres() {
    local target_dir="$BACKUP_DIR/postgres"
    mkdir -p "$target_dir"

    log "Starting PostgreSQL backup..."

    # 检查容器是否正常运行
    if ! docker ps --format '{{.Names}}' | grep -wq "postgres"; then
        log "WARNING: postgres container is not running, skipping PostgreSQL backup"
        return 0
    fi

    # 获取业务数据库列表
    # 显式加入 -h 127.0.0.1 走 TCP 协议，避免走 UNIX Socket 触发文件权限问题
    local databases
    databases=$(
        docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-}" postgres \
            psql -h 127.0.0.1 -U "$POSTGRES_USER" -tAc \
            "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';"
    )

    # -------------------------
    # 备份 postgres 默认数据库
    # -------------------------
    local postgres_dump="$target_dir/postgres_${TIMESTAMP}.sql.gz"

    docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-}" postgres \
        pg_dump -h 127.0.0.1 -U "$POSTGRES_USER" postgres \
        | gzip > "$postgres_dump"

    # 检查文件是否有效
    if [ ! -s "$postgres_dump" ]; then
        log "ERROR: PostgreSQL default db backup failed"
        rm -f "$postgres_dump"
        exit 1
    fi

    log "PostgreSQL database -> $postgres_dump"

    # -------------------------
    # 备份业务数据库
    # -------------------------
    for db in $databases; do
        local db_dump="$target_dir/${db}_${TIMESTAMP}.sql.gz"

        docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-}" postgres \
            pg_dump -h 127.0.0.1 -U "$POSTGRES_USER" "$db" \
            | gzip > "$db_dump"

        if [ ! -s "$db_dump" ]; then
            log "WARNING: database $db backup failed"
            rm -f "$db_dump"
            continue
        fi

        log "Database $db -> $db_dump"
    done

    # 删除超过保留时间的备份
    find "$target_dir" -type f -name "*.sql.gz" -mtime +"$RETENTION_DAYS" -delete

    log "PostgreSQL backup completed"
}

# =========================================================
# Gitea备份
# =========================================================

backup_gitea() {
    local target_dir="$BACKUP_DIR/gitea"
    mkdir -p "$target_dir"

    log "Starting Gitea backup..."

    if ! docker ps --format '{{.Names}}' | grep -wq "gitea"; then
        log "WARNING: gitea container is not running, skipping Gitea backup"
        return 0
    fi

    local filename="gitea-dump-${TIMESTAMP}.zip"
    local container_tmp_path="/tmp/${filename}"

    # 在容器内的临时目录执行（-w /tmp）：gitea dump 会在当前工作目录打包，
    # 不在可写目录下执行会因权限问题失败（见官方文档 Docker 章节）
    docker exec -w /tmp gitea \
        gitea dump \
        -c /data/gitea/conf/app.ini \
        -f "$container_tmp_path"

    # 从容器复制备份文件到宿主机
    docker cp "gitea:$container_tmp_path" "$target_dir/$filename"

    # 删除容器内的临时备份文件
    docker exec gitea rm -f "$container_tmp_path" || true

    # 清理宿主机旧备份
    find "$target_dir" -type f -name "gitea-dump-*.zip" -mtime +"$RETENTION_DAYS" -delete

    log "Gitea backup completed"
}

# =========================================================
# Vaultwarden备份
# =========================================================

backup_vaultwarden() {
    local target_dir="$BACKUP_DIR/vaultwarden"
    local data_dir="$PROJECT_DIR/appdata/vaultwarden"

    mkdir -p "$target_dir"

    # 注意：这里不能加 "|| true"。加上之后整个条件恒为真，
    # 无论容器是否存在都会 return 0，导致 Vaultwarden 永远不会被备份。
    if ! docker ps -a --format '{{.Names}}' | grep -wq "vaultwarden"; then
        log "Vaultwarden container not found, skip backup"
        return 0
    fi

    log "Starting Vaultwarden backup..."

    # 1. 停止服务（保证 SQLite 一致性）
    log "Stopping vaultwarden for consistent backup..."
    compose stop vaultwarden || true

    # 2. 打包数据目录
    local backup_file="$target_dir/vaultwarden_${TIMESTAMP}.tar.gz"

    if [ -d "$data_dir" ] && [ "$(ls -A "$data_dir" 2> /dev/null)" ]; then
        tar -czf "$backup_file" \
            -C "$PROJECT_DIR/appdata" \
            vaultwarden

        if [ ! -s "$backup_file" ]; then
            log "ERROR: Vaultwarden backup file is empty"
            compose start vaultwarden || true
            exit 1
        fi

        log "Vaultwarden data -> $backup_file"
    else
        log "WARNING: Vaultwarden data directory is empty or missing"
    fi

    # 3. 启动服务
    log "Starting vaultwarden..."
    compose start vaultwarden || true

    # 4. 清理超过保留天数的备份
    find "$target_dir" -type f -name "vaultwarden_*.tar.gz" -mtime +"$RETENTION_DAYS" -delete

    log "Vaultwarden backup completed"
}

# =========================================================
# 主流程
# =========================================================

main() {
    log "================================="
    log "Backup started"
    log "================================="

    load_env
    check_docker

    backup_postgres
    backup_gitea
    backup_vaultwarden

    log "================================="
    log "Backup completed"
    log "================================="
}

main "$@"
