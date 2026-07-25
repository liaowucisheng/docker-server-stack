update() {
  log "Updating Nginx Proxy Manager..."
  compose pull npm
  compose up -d --no-deps npm
  local i
  for i in $(seq 1 12); do
    if docker exec npm wget -qO- http://localhost:81/ >/dev/null 2>&1; then
      info "NPM health check passed"
      return 0
    fi
    sleep 5
  done
  error "NPM health check failed"
  return 1
}
