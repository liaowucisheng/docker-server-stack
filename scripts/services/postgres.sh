update() {
  log "Updating PostgreSQL..."
  compose pull postgres
  compose up -d --no-deps postgres
  local i
  for i in $(seq 1 12); do
    if docker exec postgres pg_isready -U "${POSTGRES_USER}" >/dev/null 2>&1; then
      info "PostgreSQL health check passed"
      return 0
    fi
    sleep 5
  done
  error "PostgreSQL health check failed"
  return 1
}
