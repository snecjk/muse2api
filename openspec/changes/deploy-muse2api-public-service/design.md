## 部署结构

```text
公网用户
   │ HTTPS
   ▼
muse.litemall.asia
   │
   ▼
现有 Caddy
   │ newapi-net
   ▼
muse2api:18610
   │
   ▼
/data/muse2api/data
```

## 实现方式

### 独立 Docker 容器

在现有服务器上新增 `muse2api` 容器，使用项目现有 Dockerfile 构建镜像。容器加入已有 `newapi-net`，不直接映射公网端口，避免额外开放服务器端口。

容器使用以下主要配置：

```text
容器名：muse2api
镜像名：muse2api:latest
网络：newapi-net
数据挂载：/data/muse2api/data:/app/data
环境文件：/data/muse2api/.env
内部端口：18610
```

生产环境必须覆盖：

```dotenv
MUSE2API_HOST=0.0.0.0
MUSE2API_PORT=18610
MUSE2API_DATA_DIR=/app/data
MUSE2API_PUBLIC_BASE=https://muse.litemall.asia
```

### Caddy 公网入口

在现有 Caddyfile 末尾增加：

```caddyfile
muse.litemall.asia {
    encode gzip zstd
    reverse_proxy muse2api:18610
}
```

修改前备份 Caddyfile，配置校验通过后执行 reload，不重启 Caddy 容器。

### 部署脚本

新增 `deploy/china/deploy-muse2api.sh`，提供：

```text
start    构建并启动容器
stop     停止容器
restart  重启容器
status   查看容器和 HTTPS 状态
logs     查看容器日志
update   重新构建并替换容器
```

脚本只操作 `muse2api` 容器，不操作 `new-api`、`mysql8` 或 `redis6`。

## 数据处理

本地 `data` 目录在首次部署时上传到 `/data/muse2api/data`。更新镜像时继续使用该目录，因此账户、密钥、浏览器状态和请求记录不会丢失。

## 验证

部署后检查：

1. `muse2api` 容器正在运行。
2. 容器内访问 `/healthz` 成功。
3. `https://muse.litemall.asia/healthz` 可以访问。
4. 携带 API Key 可以访问 `/v1/models`。
5. 原有 `new-api` 域名仍可访问。
