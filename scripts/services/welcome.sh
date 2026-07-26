#!/bin/bash
#
# Welcome 服务更新脚本
# update() 函数由 update-service.sh 调用

update() {
    log "Updating Welcome page..."
    compose pull welcome
    compose up -d --no-deps welcome
    info "Welcome service updated"
}
