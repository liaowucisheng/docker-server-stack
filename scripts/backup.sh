#!/bin/bash

# =========================================================
# Docker Self-hosted Server Stack Backup Script
#
# Backup:
#   1. PostgreSQL databases
#   2. Gitea repositories and configuration
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
# -e: 命令失败退出
# -u: 使用未定义变量退出
# pipefail: 管道任意一步失败都算失败
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
#
# 备份:
#   postgres 默认数据库
#   Gitea业务数据库
#
# 输出:
#   data/backup/postgres
#
# =========================================================

backup_postgres() {

    local target_dir="$BACKUP_DIR/postgres"

    mkdir -p "$target_dir"

    log "Starting PostgreSQL backup..."

    # 获取业务数据库列表
    #
    # 排除:
    # template数据库
    # postgres默认库

    local databases

    databases=$(
        docker exec postgres \
            psql \
            -U "$POSTGRES_USER" \
            -tAc \
            "
        SELECT datname
        FROM pg_database
        WHERE datistemplate = false
        AND datname != 'postgres';
        "
    )

    # -------------------------
    # 备份postgres默认数据库
    # -------------------------

    local postgres_dump

    postgres_dump="$target_dir/postgres_${TIMESTAMP}.sql.gz"

    docker exec postgres \
        pg_dump \
        -U "$POSTGRES_USER" \
        postgres \
        | gzip > "$postgres_dump"

    # 检查文件是否有效

    if [ ! -s "$postgres_dump" ]; then

        log "ERROR: PostgreSQL backup failed"

        rm -f "$postgres_dump"

        exit 1

    fi

    log "PostgreSQL database -> $postgres_dump"

    # -------------------------
    # 备份业务数据库
    # -------------------------

    for db in $databases; do

        local db_dump

        db_dump="$target_dir/${db}_${TIMESTAMP}.sql.gz"

        docker exec postgres \
            pg_dump \
            -U "$POSTGRES_USER" \
            "$db" \
            | gzip > "$db_dump"

        if [ ! -s "$db_dump" ]; then

            log "WARNING: database $db backup failed"

            rm -f "$db_dump"

            continue

        fi

        log "Database $db -> $db_dump"

    done

    # 删除超过保留时间的备份

    find "$target_dir" \
        -type f \
        -name "*.sql.gz" \
        -mtime +"$RETENTION_DAYS" \
        -delete

    log "PostgreSQL backup completed"

}

# =========================================================
# Gitea备份
#
# 使用官方:
#   gitea dump
#
# 输出:
#   data/backup/gitea
#
# =========================================================

backup_gitea() {

    local target_dir="$BACKUP_DIR/gitea"

    mkdir -p "$target_dir"

    log "Starting Gitea backup..."

    # Gitea dump临时目录

    local tmp_dir="/tmp/gitea-backup-${TIMESTAMP}"

    mkdir -p "$tmp_dir"

    # 在容器内部生成备份

    docker exec gitea \
        gitea dump \
        -c /data/gitea/conf/app.ini \
        --file "gitea-dump-${TIMESTAMP}.zip"

    local dump_file

    dump_file="/tmp/gitea-dump-${TIMESTAMP}.zip"

    # 从容器复制备份文件

    docker cp \
        "gitea:$dump_file" \
        "$target_dir/"

    # 删除容器临时文件

    docker exec gitea \
        rm -f "$dump_file" \
        || true

    # 清理旧备份

    find "$target_dir" \
        -type f \
        -name "gitea-dump-*.zip" \
        -mtime +"$RETENTION_DAYS" \
        -delete

    log "Gitea backup completed"

}

# =========================================================
# Vaultwarden备份
#
# 策略：
#   1. 短暂停止容器保证 SQLite 一致性
#   2. 打包整个 data 目录（包含 db.sqlite3、附件、rsa_key 等）
#   3. 启动容器
#   4. 清理过期备份
#
# 输出：
#   data/backup/vaultwarden/vaultwarden_YYYYMMDD_HHMMSS.tar.gz
# =========================================================

backup_vaultwarden() {
    local target_dir="$BACKUP_DIR/vaultwarden"
    local data_dir="$PROJECT_DIR/appdata/vaultwarden"

    mkdir -p "$target_dir"

    # 检查容器是否存在
    if ! docker ps -a --format '{{.Names}}' | grep -q "^vaultwarden$"; then
        log "Vaultwarden container not found, skip backup"
        return 0
    fi

    log "Starting Vaultwarden backup..."

    # 1. 停止服务（保证 SQLite 一致性，个人使用通常只需几秒）
    log "Stopping vaultwarden for consistent backup..."
    compose stop vaultwarden

    # 2. 打包数据目录
    local backup_file="$target_dir/vaultwarden_${TIMESTAMP}.tar.gz"

    if [ -d "$data_dir" ] && [ "$(ls -A "$data_dir" 2> /dev/null)" ]; then
        tar -czf "$backup_file" \
            -C "$PROJECT_DIR/appdata" \
            vaultwarden

        if [ ! -s "$backup_file" ]; then
            log "ERROR: Vaultwarden backup file is empty"
            compose start vaultwarden
            exit 1
        fi

        log "Vaultwarden data -> $backup_file"
    else
        log "WARNING: Vaultwarden data directory is empty or missing"
    fi

    # 3. 启动服务
    log "Starting vaultwarden..."
    compose start vaultwarden

    # 4. 清理超过保留天数的备份
    find "$target_dir" \
        -type f \
        -name "vaultwarden_*.tar.gz" \
        -mtime +"$RETENTION_DAYS" \
        -delete

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
