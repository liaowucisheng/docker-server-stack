update() {
    log "Updating Code Server..."
    compose pull code-server
    compose up -d --no-deps code-server
    local i
    for i in $(seq 1 12); do
        if docker exec code-server wget -qO- http://localhost:8080/ > /dev/null 2>&1; then
            info "Code Server health check passed"
            return 0
        fi
        sleep 5
    done
    error "Code Server health check failed"
    return 1
}
