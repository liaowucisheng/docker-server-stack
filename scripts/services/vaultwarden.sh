update() {
    log "Updating Vaultwarden..."
    compose pull vaultwarden
    compose up -d --no-deps vaultwarden
    # 健康检查
    local i
    for i in $(seq 1 12); do
        if docker exec vaultwarden curl -sf http://localhost:80/alive > /dev/null 2>&1; then
            info "Vaultwarden health check passed"
            return 0
        fi
        sleep 5
    done
    error "Vaultwarden health check failed"
    return 1
}
