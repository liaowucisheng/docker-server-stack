#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

load_env
check_docker

log "========================================="
log "Smart Deploy"
log "========================================="

cd "$PROJECT_DIR"

# --------------------------------------------------
# 1. 获取 SHA
# --------------------------------------------------

CURRENT_SHA=$(git rev-parse HEAD)
LAST_SHA_FILE="$STATE_DIR/last_deployed_sha"

# 确保 .state 目录存在
mkdir -p "$STATE_DIR"

if [ -f "$LAST_SHA_FILE" ]; then
    LAST_SHA=$(cat "$LAST_SHA_FILE")
else
    # 首次部署：从头 diff
    LAST_SHA=$(git rev-list --max-parents=0 HEAD)
    log "First deploy — comparing against initial commit"
fi

log "Current SHA : $CURRENT_SHA"
log "Last SHA   : $LAST_SHA"

# 如果 SHA 相同则跳过
if [ "$CURRENT_SHA" = "$LAST_SHA" ]; then
    info "No new commits since last deploy, skipping"
    exit 0
fi

# --------------------------------------------------
# 2. 获取变更文件列表
# --------------------------------------------------

FORCE_FULL_DEPLOY=false
CHANGED=""

# git diff 失败时不能当成“无变更”：例如 .state 里记录的 SHA 已被 gc 清理，
# 或历史被强推覆盖。那样会永久跳过部署，所以这里降级为全量部署。
if ! CHANGED=$(git diff --name-only "$LAST_SHA".."$CURRENT_SHA" 2> /dev/null); then
    warn "git diff '$LAST_SHA..$CURRENT_SHA' failed — falling back to full deploy"
    FORCE_FULL_DEPLOY=true
    CHANGED=""
fi

if $FORCE_FULL_DEPLOY; then
    log "Diff unavailable — full deploy"
    ./scripts/update-all.sh
    echo "$CURRENT_SHA" > "$LAST_SHA_FILE"
    info "Deploy completed (full)"
    exit 0
fi

if [ -z "$CHANGED" ]; then
    info "No file changes detected, skipping"
    echo "$CURRENT_SHA" > "$LAST_SHA_FILE"
    exit 0
fi

log "Changed files:"
echo "$CHANGED" | while IFS= read -r f; do echo "  $f"; done

# --------------------------------------------------
# 3. 判断是否仅文档变更
# --------------------------------------------------

ONLY_DOCS=true
while IFS= read -r f; do
    case "$f" in
        *.md | *.txt | *.gitignore | *.mdx) ;;
        *)
            ONLY_DOCS=false
            break
            ;;
    esac
done <<< "$CHANGED"

if $ONLY_DOCS; then
    info "Only documentation changed, skipping deployment"
    echo "$CURRENT_SHA" > "$LAST_SHA_FILE"
    exit 0
fi

# --------------------------------------------------
# 4. 检查全局配置变更
# --------------------------------------------------

GLOBAL_CHANGE=false
while IFS= read -r f; do
    case "$f" in
        .env | compose/compose.base.yml | compose/compose.override.yml)
            GLOBAL_CHANGE=true
            break
            ;;
    esac
done <<< "$CHANGED"

if $GLOBAL_CHANGE; then
    log "Global configuration changed — full deploy"
    ./scripts/update-all.sh
    echo "$CURRENT_SHA" > "$LAST_SHA_FILE"
    info "Deploy completed (full)"
    exit 0
fi

# --------------------------------------------------
# 5. 逐服务映射
# --------------------------------------------------

SERVICES=()

while IFS= read -r f; do
    case "$f" in
        compose/compose.infra.yml | scripts/services/postgres.sh)
            SERVICES+=("postgres")
            ;;
        compose/compose.gitea.yml | scripts/services/gitea.sh)
            SERVICES+=("gitea")
            ;;
        compose/compose.npm.yml | scripts/services/npm.sh)
            SERVICES+=("npm")
            ;;
        compose/compose.code-server.yml | scripts/services/code-server.sh)
            SERVICES+=("code-server")
            ;;
        compose/compose.welcome.yml)
            SERVICES+=("welcome")
            ;;
        compose/compose.vaultwarden.yml | scripts/services/vaultwarden.sh)
            SERVICES+=("vaultwarden")
            ;;
    esac
done <<< "$CHANGED"

# 去重并排序
# 注意：SERVICES 为空时 printf 仍会输出一个空行，mapfile 会得到一个内容为
# 空字符串的元素，后面会被误判成“单服务更新”并调用 update-service.sh ""，
# 该脚本直接 usage 退出，导致部署失败。所以这里显式判空。
UNIQUE_SERVICES=()
if [ ${#SERVICES[@]} -gt 0 ]; then
    mapfile -t UNIQUE_SERVICES < <(printf "%s\n" "${SERVICES[@]}" | sort -u)
fi

# --------------------------------------------------
# 6. 执行更新
# --------------------------------------------------

if [ ${#UNIQUE_SERVICES[@]} -eq 0 ]; then
    log "Changes detected but no specific service match — full deploy"
    ./scripts/update-all.sh
elif [ ${#UNIQUE_SERVICES[@]} -eq 1 ]; then
    log "Updating single service: ${UNIQUE_SERVICES[0]}"
    ./scripts/update-service.sh "${UNIQUE_SERVICES[0]}"
else
    log "Multiple services changed (${UNIQUE_SERVICES[*]}) — full deploy"
    ./scripts/update-all.sh
fi

# --------------------------------------------------
# 7. 保存 SHA
# --------------------------------------------------

echo "$CURRENT_SHA" > "$LAST_SHA_FILE"
info "Deploy completed"
