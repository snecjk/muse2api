# muse2api 公网部署方案

本文档描述如何将 `muse2api` 作为独立服务部署到现有 `new-api` 服务器，并通过
`https://muse.litemall.asia` 对外提供服务。部署必须与服务器上的 `new-api`、MySQL、
Redis 等既有应用隔离。

> 本文是部署设计文档。配套的可执行部署脚本尚未创建。

## 1. 部署目标

- 公网域名：`muse.litemall.asia`
- HTTPS 入口：复用服务器已有 Caddy
- 容器名称：`muse2api`
- Docker 镜像：`muse2api-custom:latest`
- 容器内部端口：`18610`
- Docker 网络：复用 `newapi-net`
- 持久化根目录：`/data/muse2api`
- 不向公网直接映射 `18610`
- 不修改或重建 `new-api`、`mysql8`、`redis6`

目标拓扑：

```text
Internet
    |
    | HTTPS :443
    v
Caddy
    |
    | Docker network: newapi-net
    v
muse2api:18610
    |
    v
/data/muse2api/data
```

## 2. 隔离原则

部署和更新过程中必须遵守以下约束：

1. 不执行 `docker compose down`。
2. 不停止或重启 `new-api`、`mysql8`、`redis6`。
3. 不删除或重建 `newapi-net`。
4. 不覆盖 `/data/new-api`、`/data/mysql`、`/data/redis`、`/data/caddy`。
5. `muse2api` 使用独立容器、镜像、环境文件和数据目录。
6. 新镜像构建成功后才能替换旧的 `muse2api` 容器。
7. Caddy 新配置必须先通过校验，再执行无中断 reload。
8. 更新失败时保留旧镜像和持久化数据，以便回滚。

## 3. 服务器目录

```text
/data/muse2api/
├── src/                 # 服务端源码
├── data/                # 账户、密钥、浏览器 Profile、请求数据库和媒体文件
├── env                  # 生产环境变量，权限 600
└── backups/             # 更新前的数据快照
```

推荐权限：

```text
/data/muse2api/env        600
/data/muse2api/data       仅部署用户和容器用户可读写
/data/muse2api/backups    仅部署用户可读写
```

不得将生产环境的 `env`、`accounts.json`、`keys.json`、`api_key` 或浏览器 Profile
提交到 Git。

## 4. 生产环境配置

服务器的 `/data/muse2api/env` 应基于项目 `.env.example` 创建。至少需要确认：

```dotenv
MUSE2API_HOST=0.0.0.0
MUSE2API_PORT=18610
MUSE2API_PUBLIC_BASE=https://muse.litemall.asia
MUSE2API_DATA_DIR=/app/data

MUSE2API_API_KEY=<生成独立强密钥>
MUSE2API_ADMIN_KEY=<生成另一个独立强密钥>

MUSE2API_DRIVER=browser
MUSE2API_SITE_URL=https://muse.ai
MUSE2API_CHROMIUM_PATH=/usr/bin/chromium
MUSE2API_BROWSER_PROFILE_DIR=/app/data/browser-profile
MUSE2API_HEADLESS=true
```

注意事项：

- 容器内不能使用 `MUSE2API_HOST=127.0.0.1`，否则 Caddy 无法访问服务。
- `MUSE2API_PUBLIC_BASE` 必须是最终 HTTPS 域名，否则媒体链接可能返回错误地址。
- API 密钥与管理密钥必须不同，并且不得复用 `new-api` 的任何密码或会话密钥。
- 首次上线建议降低预热线程和账户并发，观察内存后再调整。

建议的保守初始值：

```dotenv
MUSE2API_WARM_THREADS=0
MUSE2API_ACCOUNT_MAX_CONCURRENCY=1
```

## 5. Docker 容器约束

容器应具备以下属性：

```text
name:             muse2api
image:            muse2api-custom:latest
restart:          unless-stopped
network:          newapi-net
internal port:    18610
published ports:  none
volume:           /data/muse2api/data:/app/data
shm size:         1 GB
health endpoint:  http://127.0.0.1:18610/healthz
```

不发布宿主机端口的情况下，Caddy 可通过相同 Docker 网络访问：

```text
http://muse2api:18610
```

## 6. DNS 与 Caddy

DNS 需要增加记录：

```text
类型：A
主机记录：muse
值：140.143.183.34
```

等待 DNS 生效后，在现有 Caddyfile 中追加独立站点，不能覆盖已有站点：

```caddyfile
muse.litemall.asia {
	encode gzip zstd
	reverse_proxy muse2api:18610
}
```

Caddy 与 `muse2api` 必须同时连接到 `newapi-net`。

修改配置时的安全顺序：

1. 备份当前 Caddyfile。
2. 在临时文件中追加 `muse.litemall.asia` 站点。
3. 使用 Caddy 容器校验临时配置。
4. 校验成功后替换正式配置。
5. 使用 `caddy reload` 热加载，不重建 Caddy 容器。
6. HTTPS 验证失败时恢复备份并再次 reload。

## 7. 数据迁移

需要迁移的运行状态包括：

```text
data/accounts.json
data/keys.json
data/api_key
data/browser-profile/
data/requests.db
```

迁移流程：

1. 停止本地 `muse2api`，确保 SQLite 和 Chromium Profile 不再写入。
2. 删除不需要迁移的临时文件和过期媒体。
3. 打包 `data`，并记录压缩包 SHA-256。
4. 通过 SSH/SCP 上传到服务器临时目录。
5. 在 `/data/muse2api/data` 解压。
6. 设置容器用户可读写的权限。
7. 启动容器后检查账户状态与浏览器驱动健康状态。

不要只复制 `requests.db` 而遗漏正在使用的 WAL 文件。正确做法是先停止本地服务，
等待数据库关闭，再制作数据快照。

## 8. 健康检查与验收

### 容器内部

```bash
docker exec muse2api python -c \
  'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:18610/healthz").read().decode())'
```

### Caddy 到上游

```bash
docker exec caddy wget -qO- http://muse2api:18610/healthz
```

### 公网 HTTPS

```bash
curl --fail --show-error https://muse.litemall.asia/healthz
```

### API 鉴权

无密钥请求应返回 `401`：

```bash
curl -i https://muse.litemall.asia/v1/models
```

有效密钥请求应成功：

```bash
curl --fail --show-error \
  -H 'Authorization: Bearer <API_KEY>' \
  https://muse.litemall.asia/v1/models
```

### 流式请求

需要验证 SSE 能持续返回且不被代理缓存：

```bash
curl --no-buffer --fail --show-error \
  -H 'Authorization: Bearer <API_KEY>' \
  -H 'Content-Type: application/json' \
  https://muse.litemall.asia/v1/chat/completions \
  -d '{"model":"<MODEL>","messages":[{"role":"user","content":"hello"}],"stream":true}'
```

## 9. 部署脚本接口设计

后续配套脚本建议放在：

```text
deploy/deploy-muse2api.sh
```

脚本接口与现有 `new-api` 部署脚本保持一致：

```text
start      构建并启动；已有健康容器时不重复操作
stop       只停止 muse2api
restart    只重启 muse2api
status     显示容器、健康状态和公网 HTTPS 状态
logs       跟随 muse2api 日志
update     构建新镜像，健康后替换旧容器
rollback   恢复上一镜像并复用原数据目录
```

脚本必须允许使用环境变量覆盖：

```text
MUSE_IMAGE
MUSE_CONTAINER
SOURCE_DIR
DATA_DIR
ENV_FILE
SHARED_NETWORK
DOMAIN
CADDY_CONTAINER
CADDYFILE
HEALTH_WAIT_ROUNDS
HEALTH_WAIT_INTERVAL
```

## 10. 更新与回滚

安全更新顺序：

```text
同步源码
  -> 构建带唯一版本标签的新镜像
  -> 保留当前镜像 ID
  -> 备份持久化数据
  -> 只替换 muse2api 容器
  -> 等待 /healthz
  -> 验证公网 API 和 SSE
```

如果新容器未能通过健康检查：

```text
收集新容器日志
  -> 删除失败容器
  -> 使用原镜像重建 muse2api
  -> 复用原数据目录
  -> 再次验证 /healthz
```

回滚不得影响 Caddy 的其他站点，也不得操作 `new-api`、MySQL 或 Redis。

## 11. 已知注意事项

1. browser driver 会启动 Chromium，内存消耗高于普通 HTTP 服务。
2. `/dashboard` HTML 页面可以公开访问，但管理数据接口需要管理密钥。
3. `/healthz` 默认公开，不能在响应或日志中泄露账户令牌。
4. 当前基础 Dockerfile 使用 `pip install .`，没有安装 `.[matting]`；透明背景功能需要
   单独构建包含 matting 依赖的镜像。
5. 媒体文件通过公网域名返回，应配置合理的保留天数并监控磁盘空间。
6. 上线后应限制日志和备份保留周期，防止 `/data` 被媒体文件或浏览器缓存占满。

## 12. 完成标准

部署仅在满足以下条件后视为完成：

- `muse2api` 容器为 healthy。
- `new-api`、`mysql8`、`redis6` 状态与部署前一致。
- `https://muse.litemall.asia/healthz` 正常。
- 未认证的 API 请求被拒绝。
- 有效 API 密钥可以调用模型列表和非流式请求。
- SSE 流式请求可持续返回。
- Dashboard 可访问且管理接口需要管理密钥。
- 容器重启后账户、密钥、请求记录和浏览器状态仍然存在。
- Caddy 原有域名仍然正常。
