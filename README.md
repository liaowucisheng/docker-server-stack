# Self-hosted Server Stack

Docker Compose based self-hosted server stack with automated deployment and maintenance scripts.

基于 Docker Compose 的轻量化自托管服务器环境，提供统一部署、更新、备份、恢复和健康检查能力。

## Overview

本项目用于快速部署个人或小型团队使用的自托管服务器环境。

核心目标：

* 使用 Docker Compose 管理所有服务
* 使用 Git 管理服务器配置
* 数据与配置分离
* 最小化公网暴露
* 自动化部署和维护
* 支持快速迁移和灾难恢复

## Features

* Docker Compose 一键部署
* Nginx Proxy Manager HTTPS 网关
* Gitea 私有 Git 服务
* PostgreSQL 数据库
* Web VS Code 开发环境
* 自动创建 Gitea 数据库
* 独立数据库用户设计
* 自动更新脚本
* 自动备份和恢复
* 服务健康检查
* Docker 网络隔离

---

# Architecture

```
                         Internet

                            |

                         80/443

                            |

              +--------------------------+

              | Nginx Proxy Manager      |
              |          npm             |
              +------------+-------------+

                           |

                    proxy_network

                           |

          +----------------+----------------+

          |                                 |

       Gitea                         code-server

          |

          |

    backend_network

          |

      PostgreSQL


```

---

# Stack Version

| Service             | Version       |
| ------------------- | ------------- |
| Gitea               | 1.27.0        |
| PostgreSQL          | 15-bookworm   |
| Nginx Proxy Manager | 2.15.1        |
| Code Server         | 4.129.0       |
| Nginx Welcome       | stable-alpine |

---

# Services

| Service     | Description                                    |
| ----------- | ---------------------------------------------- |
| npm         | HTTPS reverse proxy and certificate management |
| gitea       | Private Git repository service                 |
| postgres    | Database service                               |
| code-server | Browser based VS Code                          |
| welcome     | Default website placeholder                    |

---

# Directory Structure

```
server/

├── compose/
│   ├── compose.base.yml          # 网络骨架
│   ├── compose.infra.yml         # PostgreSQL
│   ├── compose.gitea.yml         # Gitea + DB Init
│   ├── compose.npm.yml           # Nginx Proxy Manager
│   ├── compose.code-server.yml   # VS Code Server
│   └── compose.welcome.yml       # 默认欢迎页
│
├── .env
├── .env.example
│
├── welcome
│   └── index.html
│
├── appdata
│   ├── postgres
│   │   └── data
│   ├── gitea
│   │   ├── git
│   │   ├── gitea
│   │   └── ssh
│   ├── npm
│   │   ├── data
│   │   └── letsencrypt
│   └── code-server
│       └── config
│
├── data
│   ├── backup
│   │   ├── postgres
│   │   └── gitea
│   └── workspace
│
├── scripts
│   ├── lib.sh                    # 共享函数库
│   ├── deploy.sh                 # 智能部署入口
│   ├── install.sh                # 首次安装
│   ├── update-all.sh             # 全量更新
│   ├── update-service.sh         # 单服务更新
│   ├── healthcheck.sh            # 健康检查
│   ├── backup.sh                 # 备份
│   ├── restore.sh                # 恢复
│   ├── create-db.sh              # 创建数据库
│   └── services/
│       ├── gitea.sh
│       ├── npm.sh
│       ├── code-server.sh
│       └── postgres.sh
│
├── .github/workflows/
│   └── deploy.yml                # GitHub Actions
│
└── .state/
    └── last_deployed_sha         # 自动生成
```

---

# Network Design

## proxy_network

用于对外提供服务。

连接：

```
npm

gitea

code-server

welcome
```

作用：

* Nginx Proxy Manager 反向代理
* HTTPS 流量转发
* Web 服务访问

---

## backend_network

数据库内部网络。

连接：

```
postgres

gitea
```

特点：

```yaml
internal: true
```

作用：

* 数据库访问隔离
* 防止数据库直接暴露公网

---

# Port Design

## Public Ports

| Port  | Purpose |
| ----- | ------- |
| 80    | HTTP    |
| 443   | HTTPS   |
| 12322 | Git SSH |

---

## Local Only Ports

| Port | Purpose    |
| ---- | ---------- |
| 81   | NPM Admin  |
| 5432 | PostgreSQL |

说明：

NPM 管理后台：

```
127.0.0.1:81
```

只能服务器本机访问。

PostgreSQL：

```
127.0.0.1:5432
```

避免公网扫描和暴力攻击。

---

# Installation

## Requirements

推荐环境：

* Ubuntu Server 22.04+
* Docker Engine
* Docker Compose v2
* Git

检查：

```bash
docker --version

docker compose version

git --version
```

---

# Deploy

## 1. Clone Repository

```bash
git clone https://github.com/liaowucisheng/docker-server-stack.git /data/server

cd /data/server
```

---

## 2. Create Environment

复制环境模板：

```bash
cp .env.example .env
```

编辑：

```bash
vim .env
```

需要修改：

* 域名
* 密码
* 数据库密码
* 服务端口

---

## 3. Start Installation

执行：

```bash
chmod +x scripts/*.sh

./scripts/install.sh
```

安装脚本会执行：

1. 检查 Docker 环境
2. 创建数据目录
3. 检查配置文件
4. 拉取 Docker 镜像
5. 启动服务

---

# Gitea SSH Configuration

Gitea 使用独立 SSH 端口。

配置：

```yaml
GITEA__server__SSH_PORT: 12322

GITEA__server__SSH_LISTEN_PORT: 22
```

含义：

| 项目        | 端口    |
| --------- | ----- |
| 宿主机       | 12322 |
| Docker容器  | 22    |
| Gitea显示端口 | 12322 |

因此 Git SSH 地址：

```bash
git clone ssh://git@git.example.com:12322/user/repository.git
```

---

# Database

## PostgreSQL

PostgreSQL 不直接提供公网访问。

连接：

```
Host:

postgres


Port:

5432
```

Docker 内部服务：

```
postgres:5432
```

---

## Gitea Database

Gitea 使用独立数据库：

```
Database:

giteadb


User:

gitea
```

初始化：

```
gitea-db-init
```

首次启动自动创建。

---

# Maintenance

## Health Check

检查服务：

```bash
./scripts/healthcheck.sh
```

检查：

* Docker
* Container 状态
* Healthcheck
* PostgreSQL
* Gitea
* NPM
* 磁盘
* 内存

---

# Update

## 全量更新

更新所有服务：

```bash
./scripts/update-all.sh
```

## 单服务更新

更新指定服务：

```bash
./scripts/update-service.sh gitea
./scripts/update-service.sh npm
./scripts/update-service.sh code-server
./scripts/update-service.sh postgres
```

## 智能部署

通过 Git diff 自动判断变更范围，仅部署受影响的服务：

```bash
./scripts/deploy.sh
```

逻辑：
- 仅文档变更 → 跳过
- 全局配置 (.env / base.yml) → 全量更新
- 单服务文件变更 → 仅更新对应服务
- 混合变更 → 全量更新（安全兜底）

## GitHub Actions 自动部署

推送 `main` 分支后自动触发：

```bash
git push origin main
```

GitHub Actions 通过 SSH 登录服务器，执行 `deploy.sh` 完成智能部署。

---

# Backup

执行：

```bash
./scripts/backup.sh
```

备份目录：

```
data/backup
```

包含：

```
PostgreSQL

Gitea 数据
```

---

# Restore

恢复前：

建议停止相关服务。

恢复 PostgreSQL：

```bash
./scripts/restore.sh postgres backup.sql.gz
```

恢复 Gitea：

```bash
./scripts/restore.sh gitea backup.zip
```

注意：

恢复前必须确认：

* Gitea 版本一致
* PostgreSQL 版本一致
* 已完成当前数据备份

---

# Create Database

新增服务数据库：

例如：

```bash
./scripts/create-db.sh nextcloud nextcloud_user
```

自动创建：

* Database
* User
* Password
* Permissions

---

# Security

当前安全设计：

## 最小公网暴露

公网：

```
80
443
12322
```

内部：

```
5432

81
```

---

## Container Security

启用：

```yaml
init: true
```

禁止权限提升：

```yaml
security_opt:

  - no-new-privileges:true
```

---

## Data Separation

配置：

```
appdata
```

数据：

```
data
```

代码：

```
git repository
```

三者分离。

---

# Recovery Process

服务器迁移流程：

```
安装 Docker

↓

Clone Repository

↓

恢复 .env

↓

恢复 backup

↓

执行 install.sh

↓

healthcheck

```

---

# Project Management

推荐日常流程：

## 修改配置

```
修改 compose/compose.*.yml

↓

git commit

↓

git push
```

服务器自动部署（GitHub Actions + deploy.sh）：

```
git push origin main

↓

GitHub Actions 触发

↓

服务器执行 ./scripts/deploy.sh

↓

智能判断变更范围并更新
```

---

## Routine Maintenance

建议：

每天：

```
healthcheck.sh
```

定期：

```
backup.sh
```

升级：

```
update-all.sh
```

---

# Project Philosophy

本项目遵循：

* Infrastructure as Code
* Configuration as Code
* Data Persistence Separation
* Least Exposure Principle
* Automated Maintenance

目标：

使用简单的 Docker Compose 构建一个稳定、可迁移、易维护的个人服务器平台。

---

# License

MIT License

---

