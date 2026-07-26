update() {
    log "Updating Gitea..."
    compose pull gitea
    compose up -d --no-deps gitea
    # 健康检查
    local i
    for i in $(seq 1 12); do
        if docker exec gitea wget -qO- http://localhost:3000/api/health > /dev/null 2>&1; then
            info "Gitea health check passed"
            return 0
        fi
        sleep 5
    done
    error "Gitea health check failed"
    return 1
}
