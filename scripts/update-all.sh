#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

load_env
check_docker

log "========================================="
log "Full update — all services"
log "========================================="

log "Pulling all images..."
compose pull

log "Recreating all services..."
compose up -d --remove-orphans

log "Waiting for services to be healthy..."
sleep 15
compose ps

log "Cleaning unused images..."
docker image prune -f

log "========================================="
log "Full update completed"
log "========================================="
