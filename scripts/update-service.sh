#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  echo "Usage: $0 <service-name>"
  echo ""
  echo "Services: gitea, npm, code-server, postgres"
  exit 1
}

SERVICE="${1:-}"
[ -n "$SERVICE" ] || usage

SERVICE_SCRIPT="$SCRIPT_DIR/services/${SERVICE}.sh"
if [ ! -f "$SERVICE_SCRIPT" ]; then
  error "Unknown service: $SERVICE"
  error "No script found at $SERVICE_SCRIPT"
  exit 1
fi

load_env
check_docker

log "========================================="
log "Updating service: $SERVICE"
log "========================================="

source "$SERVICE_SCRIPT"
update

log "Cleaning unused images..."
docker image prune -f

log "Service $SERVICE update completed"
