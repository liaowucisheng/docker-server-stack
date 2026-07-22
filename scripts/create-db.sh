#!/bin/bash

# =========================================================
# PostgreSQL Database Create Script
#
# 功能:
#   创建新的 PostgreSQL 数据库和独立用户
#
# 用途:
#   为新增 Docker 服务创建独立数据库
#
# 示例:
#
#   ./create-db.sh nextcloud nextcloud_user
#
#   ./create-db.sh appdb appuser my_password
#
#
# 注意:
#   Gitea 数据库由 docker-compose.yml 中
#   gitea-db-init 服务自动创建
#
# =========================================================

# 遇到错误立即退出
# -e: 命令失败退出
# -u: 未定义变量退出
# pipefail: 管道失败退出

set -euo pipefail

# =========================================================
# 路径配置
# =========================================================

# 当前脚本目录

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 项目根目录

PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

    echo "ERROR: .env file not found"

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
# 使用说明
# =========================================================

usage()
{

cat <<EOF

Usage:

  $0 <database_name> <username> [password]

Examples:

  自动生成密码:

    $0 nextcloud nextcloud_user

  指定密码:

    $0 appdb appuser StrongPassword123

Parameters:

  database_name:
      PostgreSQL数据库名称

  username:
      数据库用户名

  password:
      可选，不提供时自动生成

EOF

exit 1

}

# =========================================================
# 检查Docker环境
# =========================================================

check_environment()
{

    # 检查Docker

    if ! docker info >/dev/null 2>&1
    then

        log "ERROR: Docker is not running"

        exit 1

    fi

    # 检查postgres容器

    if ! docker ps \
        --format '{{.Names}}' \
        | grep -q "^postgres$"
    then

        log "ERROR: postgres container is not running"

        exit 1

    fi

}

# =========================================================
# 校验数据库名称和用户名
# =========================================================

validate_name()
{

    local name="$1"
    local type="$2"

    if ! [[ "$name" =~ ^[a-z][a-z0-9_]+$ ]]
    then

        echo "Invalid $type name: $name"

        echo "Allowed:"
        echo "  lowercase letters"
        echo "  numbers"
        echo "  underscore"

        exit 1

    fi

}

# =========================================================
# 创建数据库
# =========================================================

create_database()
{

    local db_name="$1"

    log "Checking database: $db_name"

    local exists

    exists=$(docker exec postgres \
        psql \
        -U "$POSTGRES_USER" \
        -d postgres \
        -tAc \
        "SELECT 1 FROM pg_database WHERE datname='$db_name'"
    )

    if [ "$exists" = "1" ]
    then

        log "Database '$db_name' already exists"

    else

        docker exec postgres \
            psql \
            -U "$POSTGRES_USER" \
            -c "CREATE DATABASE \"$db_name\""

        log "Created database '$db_name'"

    fi

}

# =========================================================
# 创建数据库用户
# =========================================================

create_user()
{

    local username="$1"
    local password="$2"

    log "Checking user: $username"

    local exists

    exists=$(docker exec postgres \
        psql \
        -U "$POSTGRES_USER" \
        -d postgres \
        -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname='$username'"
    )

    if [ "$exists" = "1" ]
    then

        log "User '$username' already exists"

    else

        docker exec postgres \
            psql \
            -U "$POSTGRES_USER" \
            -c "CREATE USER \"$username\" WITH PASSWORD '$password'"

        log "Created user '$username'"

    fi

}

# =========================================================
# 授权数据库
# =========================================================

grant_permission()
{

    local db_name="$1"
    local username="$2"

    log "Granting privileges..."

    docker exec postgres \
        psql \
        -U "$POSTGRES_USER" \
        -c "GRANT ALL PRIVILEGES ON DATABASE \"$db_name\" TO \"$username\""

    docker exec postgres \
        psql \
        -U "$POSTGRES_USER" \
        -d "$db_name" \
        -c "GRANT ALL ON SCHEMA public TO \"$username\""

}

# =========================================================
# 主程序
# =========================================================

main()
{

    # 参数检查

    [ $# -ge 2 ] || usage

    local db_name="$1"

    local db_user="$2"

    local db_password="${3:-}"

    validate_name "$db_name" "database"

    validate_name "$db_user" "username"

    # 没有指定密码则自动生成

    if [ -z "$db_password" ]
    then

        db_password=$(openssl rand -base64 32)

    fi

    check_environment

    log "================================="
    log "Creating PostgreSQL database"
    log "================================="

    log "Database : $db_name"

    log "User     : $db_user"

    create_database "$db_name"

    create_user "$db_user" "$db_password"

    grant_permission "$db_name" "$db_user"

    echo

    echo "================================="
    echo " Database setup completed"
    echo "================================="

    echo

    echo "Database:"
    echo "  $db_name"

    echo

    echo "User:"
    echo "  $db_user"

    echo

    echo "Password:"
    echo "  $db_password"

    echo

    echo "Connection:"
    echo "  Host: postgres"

    echo "  Port: 5432"

    echo "  Database: $db_name"

    echo

    echo "URL:"
    echo "  postgresql://$db_user:$db_password@postgres:5432/$db_name"

    echo "================================="

}

main "$@"