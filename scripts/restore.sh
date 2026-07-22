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

# =========================================================
# 路径
# =========================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BACKUP_DIR="$PROJECT_DIR/data/backup"

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
# 使用说明
# =========================================================

usage()
{

cat <<EOF

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

check_environment()
{

    if ! docker info >/dev/null 2>&1

    then

        log "ERROR: Docker is not running"

        exit 1

    fi

    if ! docker ps \
        --format '{{.Names}}' \
        | grep -q "^postgres$"

    then

        log "ERROR: postgres container not running"

        exit 1

    fi

}

# =========================================================
# 安全确认
# =========================================================

confirm()
{

read -rp "
WARNING:
This operation will overwrite current data.

Continue? (yes/no): " answer

if [ "$answer" != "yes" ]

then

    echo "Cancelled"

    exit 0

fi

}

# =========================================================
# PostgreSQL恢复
# =========================================================

restore_postgres()
{

local file="$1"

local backup_file="$BACKUP_DIR/postgres/$file"

if [ ! -f "$backup_file" ]

then

    log "Backup file not found:"
    echo "$backup_file"

    exit 1

fi

confirm

log "Stopping application containers..."

docker compose stop gitea

log "Restoring PostgreSQL..."

gunzip -c "$backup_file" | \
docker exec -i postgres \
psql \
-U "$POSTGRES_USER" \
postgres

log "PostgreSQL restore completed"

}

# =========================================================
# Gitea恢复
# =========================================================

restore_gitea()
{

local file="$1"

local backup_file="$BACKUP_DIR/gitea/$file"

if [ ! -f "$backup_file" ]

then

    log "Backup file not found:"
    echo "$backup_file"

    exit 1

fi

confirm

log "Stopping Gitea..."

docker compose stop gitea

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

}

# =========================================================
# 主程序
# =========================================================

main()
{

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

*)

    usage

    ;;

esac

log "Restore finished"

}

main "$@"