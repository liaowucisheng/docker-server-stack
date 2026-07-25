#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

load_env

FAILED=0

check_docker() {
  if docker info >/dev/null 2>&1; then
    info "Docker service running"
  else
    error "Docker service unavailable"
    FAILED=1
  fi
}

check_containers() {
  echo ""
  echo "--------------------------------"
  echo "Container Status"
  echo "--------------------------------"
  compose ps
  local unhealthy
  unhealthy=$(compose ps --format json | grep -i unhealthy || true)
  if [ -n "$unhealthy" ]; then
    error "Some containers are unhealthy"
    FAILED=1
  else
    info "Container health status OK"
  fi
}

check_postgres() {
  echo ""
  echo "--------------------------------"
  echo "PostgreSQL"
  echo "--------------------------------"
  if docker exec postgres pg_isready -U "${POSTGRES_USER}" >/dev/null 2>&1; then
    info "PostgreSQL ready"
  else
    error "PostgreSQL unavailable"
    FAILED=1
  fi
}

check_gitea() {
  echo ""
  echo "--------------------------------"
  echo "Gitea"
  echo "--------------------------------"
  if docker exec gitea wget -qO- http://localhost:3000/api/health >/dev/null 2>&1; then
    info "Gitea HTTP OK"
  else
    error "Gitea HTTP failed"
    FAILED=1
  fi
}

check_npm() {
  echo ""
  echo "--------------------------------"
  echo "Nginx Proxy Manager"
  echo "--------------------------------"
  if docker exec npm wget -qO- http://localhost:81/ >/dev/null 2>&1; then
    info "NPM running"
  else
    error "NPM unavailable"
    FAILED=1
  fi
}

check_disk() {
  echo ""
  echo "--------------------------------"
  echo "Disk Usage"
  echo "--------------------------------"
  df -h "$PROJECT_DIR"
  local usage
  usage=$(df "$PROJECT_DIR" | awk 'NR==2 {print $5}' | tr -d '%')
  if [ "$usage" -ge 90 ]; then
    warn "Disk usage above 90%"
  else
    info "Disk usage normal"
  fi
}

check_memory() {
  echo ""
  echo "--------------------------------"
  echo "Memory"
  echo "--------------------------------"
  free -h
}

main() {
  echo ""
  echo "================================="
  echo " Docker Stack Health Check"
  echo "================================="

  check_docker
  check_containers
  check_postgres
  check_gitea
  check_npm
  check_disk
  check_memory

  echo ""
  echo "================================="
  if [ "$FAILED" -eq 0 ]; then
    info "ALL CHECKS PASSED"
    exit 0
  else
    error "HEALTH CHECK FAILED"
    exit 1
  fi
}

main "$@"
