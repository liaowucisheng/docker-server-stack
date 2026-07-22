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

# =========================================================
# 基础路径
# =========================================================

# 当前脚本目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 项目根目录
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 备份目录
BACKUP_DIR="$PROJECT_DIR/data/backup"

# 时间标签
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 保留多少天备份
RETENTION_DAYS=30

# =========================================================
# 加载环境变量
# =========================================================

ENV_FILE="$PROJECT_DIR/.env"

if [ -f "$ENV_FILE" ]; then

    # 自动导入.env变量
    set -a
    source "$ENV_FILE"
    set +a

else

    echo "ERROR: .env not found"

    exit 1

fi

# =========================================================
# 日志函数
# =========================================================

log()
{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# =========================================================
# 检查Docker状态
# =========================================================

check_docker()
{

    if ! docker info >/dev/null 2>&1
    then

        log "ERROR: Docker is not running"

        exit 1

    fi

}

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

backup_postgres()
{

    local target_dir="$BACKUP_DIR/postgres"

    mkdir -p "$target_dir"

    log "Starting PostgreSQL backup..."

    # 获取业务数据库列表
    #
    # 排除:
    # template数据库
    # postgres默认库

    local databases

    databases=$(docker exec postgres \
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

    if [ ! -s "$postgres_dump" ]
    then

        log "ERROR: PostgreSQL backup failed"

        rm -f "$postgres_dump"

        exit 1

    fi

    log "PostgreSQL database -> $postgres_dump"

    # -------------------------
    # 备份业务数据库
    # -------------------------

    for db in $databases
    do

        local db_dump

        db_dump="$target_dir/${db}_${TIMESTAMP}.sql.gz"

        docker exec postgres \
            pg_dump \
            -U "$POSTGRES_USER" \
            "$db" \
            | gzip > "$db_dump"

        if [ ! -s "$db_dump" ]
        then

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

backup_gitea()
{

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
# 主流程
# =========================================================

main()
{

    log "================================="
    log "Backup started"
    log "================================="

    check_docker

    backup_postgres

    backup_gitea

    log "================================="
    log "Backup completed"
    log "================================="

}

main "$@"