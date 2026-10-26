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

# 时间标签（安全快照、临时目录命名）
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

load_env

# =========================================================
# 使用说明
# =========================================================

usage() {

    cat << EOF

Usage:

  $0 <type> <backup_file> [database]

Types:

  postgres
      Restore PostgreSQL database
      database 可选，缺省时按备份文件名 <db>_<timestamp>.sql.gz 推断

  gitea
      Restore Gitea dump (zip)

  vaultwarden
      Restore Vaultwarden data (tar.gz)

Examples:

  Restore PostgreSQL:

  $0 postgres giteadb_20260723_030000.sql.gz

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
    local db_name="${2:-}"

    local backup_file="$BACKUP_DIR/postgres/$file"

    if [ ! -f "$backup_file" ]; then

        log "Backup file not found:"
        echo "$backup_file"

        exit 1

    fi

    # 未指定数据库时，从备份文件名推断：<db>_<timestamp>.sql.gz
    if [ -z "$db_name" ]; then

        local base
        base=$(basename "$file")

        db_name="${base%_[0-9]*_[0-9]*.sql.gz}"

        if [ "$db_name" = "$base" ]; then

            db_name="postgres"

        fi

    fi

    local exists
    exists=$(
        docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-}" postgres \
            psql -h 127.0.0.1 -U "$POSTGRES_USER" -tAc \
            "SELECT 1 FROM pg_database WHERE datname='$db_name'"
    )

    if [ "$exists" != "1" ]; then

        error "database '$db_name' does not exist"
        log "Create it first, e.g. ./scripts/create-db.sh $db_name <user>"

        exit 1

    fi

    confirm

    log "Stopping application containers..."

    compose stop gitea

    log "Restoring PostgreSQL database: $db_name"

    # ON_ERROR_STOP=1：任何一条 SQL 失败都立即退出，避免出现“恢复完成”的假象。
    # 备份是纯 SQL（未加 --clean），目标库里已存在同名表时会报错；
    # 需要整库覆盖时先清空 schema：
    #   psql -d <db> -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public'
    gunzip -c "$backup_file" \
        | docker exec -i -e PGPASSWORD="${POSTGRES_PASSWORD:-}" postgres \
            psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$db_name" \
            -v ON_ERROR_STOP=1

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

    if ! command -v unzip > /dev/null 2>&1; then

        error "unzip is required: apt-get install -y unzip"
        exit 1

    fi

    confirm

    # Gitea 没有 restore 子命令（官方文档：只能手工解压后复制文件、导入 SQL），
    # 这里按官方 Docker 流程实现：
    #   解压 -> 快照现有数据 -> 恢复数据库 -> 恢复 data/repos -> 重建 hooks/keys
    local stage="$PROJECT_DIR/data/restore/gitea-$TIMESTAMP"

    log "Extracting $backup_file ..."

    rm -rf "$stage"
    mkdir -p "$stage"
    unzip -q "$backup_file" -d "$stage"

    local dump_root
    dump_root=$(find "$stage" -mindepth 1 -maxdepth 1 -type d | head -n 1)

    if [ -z "$dump_root" ]; then

        error "unexpected dump layout: no directory inside $stage"
        exit 1

    fi

    log "Stopping Gitea..."

    compose stop gitea

    # ---------- 1. 数据库 ----------
    if [ -f "$dump_root/gitea-db.sql" ]; then

        log "Snapshotting current database before restore..."

        mkdir -p "$BACKUP_DIR/postgres"

        docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-}" postgres \
            pg_dump -h 127.0.0.1 -U "$POSTGRES_USER" "$GITEA_DB_NAME" \
            | gzip > "$BACKUP_DIR/postgres/${GITEA_DB_NAME}_pre_restore_${TIMESTAMP}.sql.gz"

        log "Recreating schema in database: $GITEA_DB_NAME"

        docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-}" postgres \
            psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$GITEA_DB_NAME" \
            -v ON_ERROR_STOP=1 \
            -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO \"${GITEA_DB_USER}\""

        log "Loading gitea-db.sql as $GITEA_DB_USER ..."

        # 以业务用户导入，恢复后的表属主才是 gitea，而不是 postgres
        docker exec -i -e PGPASSWORD="${GITEA_DB_PASSWORD}" postgres \
            psql -h 127.0.0.1 -U "$GITEA_DB_USER" -d "$GITEA_DB_NAME" \
            -v ON_ERROR_STOP=1 < "$dump_root/gitea-db.sql"

    else

        warn "gitea-db.sql not found in dump, skipping database restore"

    fi

    # ---------- 2. 文件 ----------
    local data_dir="$PROJECT_DIR/appdata/gitea"
    local safety_dir="$data_dir.bak.$TIMESTAMP"

    if [ -d "$data_dir" ]; then

        log "Moving current Gitea data to $safety_dir"
        mv "$data_dir" "$safety_dir"

    fi

    mkdir -p "$data_dir/gitea" "$data_dir/git/repositories"

    log "Restoring data and repositories..."

    # dump 里的 data/ 对应容器内 /data/gitea，repos/ 对应 /data/git/repositories
    if [ -d "$dump_root/data" ]; then

        cp -a "$dump_root/data/." "$data_dir/gitea/"

    fi

    if [ -d "$dump_root/custom" ]; then

        mkdir -p "$data_dir/gitea/custom"
        cp -a "$dump_root/custom/." "$data_dir/gitea/custom/"

    fi

    if [ -d "$dump_root/repos" ]; then

        cp -a "$dump_root/repos/." "$data_dir/git/repositories/"

    fi

    # ---------- 3. 启动、修复权限、重建 hooks/keys ----------
    log "Starting Gitea..."

    compose start gitea

    local i
    local healthy=false

    for i in $(seq 1 24); do

        if docker exec gitea wget -qO- http://localhost:3000/api/health > /dev/null 2>&1; then

            healthy=true
            break

        fi

        sleep 5

    done

    if ! $healthy; then

        error "Gitea did not become healthy after restore"
        log "Check logs: docker logs gitea"
        log "Previous data kept at: $safety_dir"

        exit 1

    fi

    # 旧数据里的 hooks 与 authorized_keys 可能指向旧路径，必须重建
    log "Regenerating git hooks and authorized_keys..."

    docker exec -u git gitea \
        gitea -c /data/gitea/conf/app.ini admin regenerate hooks \
        || warn "regenerate hooks failed, please run it manually"

    docker exec -u git gitea \
        gitea -c /data/gitea/conf/app.ini admin regenerate keys \
        || warn "regenerate keys failed, please run it manually"

    log "Cleaning staging directory..."
    rm -rf "$stage"

    log "Gitea restore completed"
    log "Previous data kept at: $safety_dir"

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

    [ $# -ge 2 ] || usage

    TYPE="$1"

    FILE="$2"

    DATABASE="${3:-}"

    check_environment

    case "$TYPE" in
        postgres)
            restore_postgres "$FILE" "$DATABASE"
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
