# 将 muse2api 部署到现有服务器

目标：在运行 `new-api` 的服务器上增加一个独立 `muse2api` Docker 容器，并通过
`https://muse.litemall.asia` 对外提供服务。

部署脚本只操作 `muse2api` 和对应的 Caddy 配置，不会停止或重建 `new-api`、
`mysql8`、`redis6`。

## 部署结构

```text
https://muse.litemall.asia
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

`18610` 不映射到服务器公网，只允许 Caddy 通过 Docker 网络访问。

## 1. 配置 DNS

在域名服务商处增加：

```text
类型：A
主机记录：muse
记录值：140.143.183.34
```

当前域名由 Cloudflare 托管（名称服务器为 `maciej.ns.cloudflare.com` 和
`romina.ns.cloudflare.com`）。在 Cloudflare DNS 中添加上述记录即可；首次签发证书时可先
使用“仅 DNS”，HTTPS 正常后再按需开启代理。

最终域名：`muse.litemall.asia`。在记录生效前，Caddy 日志会显示 `NXDOMAIN`，无法签发证书。

## 2. 上传部署脚本

在本地项目目录执行：

```bash
scp deploy/china/deploy-muse2api.sh ubuntu@<服务器IP>:~/deploy-muse2api.sh
```

## 3. 准备生产环境文件

生产环境文件保存在服务器：

```text
/data/muse2api/.env
```

可以先上传当前项目的 `.env`：

```bash
scp .env ubuntu@<服务器IP>:/tmp/muse2api.env
ssh ubuntu@<服务器IP> \
  'sudo mkdir -p /data/muse2api/data && sudo mv /tmp/muse2api.env /data/muse2api/.env && sudo chmod 600 /data/muse2api/.env'
```

上线前应确认 `.env` 中的账户、API Key、管理 Key 和代理配置适用于服务器。

以下值由部署脚本在启动容器时强制设置，不需要修改本地 `.env`：

```dotenv
MUSE2API_HOST=0.0.0.0
MUSE2API_PORT=18610
MUSE2API_DATA_DIR=/app/data
MUSE2API_PUBLIC_BASE=https://muse.litemall.asia
```

## 4. 上传现有运行数据

如果需要保留本地账户、API Key 和浏览器登录状态，先停止本地 `muse2api`，再执行：

```bash
tar -C data -czf /tmp/muse2api-data.tar.gz .
scp /tmp/muse2api-data.tar.gz ubuntu@<服务器IP>:/tmp/
ssh ubuntu@<服务器IP> \
  'sudo mkdir -p /data/muse2api/data && sudo tar -xzf /tmp/muse2api-data.tar.gz -C /data/muse2api/data'
```

首次部署且不需要迁移本地状态时，可以跳过这一步。服务会在数据目录中初始化所需文件。

## 5. 启动服务

登录服务器后执行：

```bash
sudo bash ~/deploy-muse2api.sh start
```

脚本会自动：

1. 从 GitHub 获取 `muse2api` 源码。
2. 构建 `muse2api:latest` 镜像。
3. 创建独立的 `muse2api` 容器。
4. 挂载 `/data/muse2api/data`。
5. 将容器加入现有 `newapi-net`。
6. 检查容器内 `/healthz`。
7. 在现有 Caddyfile 中加入 `muse.litemall.asia`。
8. 校验 Caddy 配置并执行热加载。

Caddyfile 修改前会自动创建带时间戳的备份。重复执行 `start` 不会重复添加域名配置。

## 6. 检查状态

```bash
sudo bash ~/deploy-muse2api.sh status
```

公网健康检查：

```bash
curl https://muse.litemall.asia/healthz
```

预期响应类似：

```json
{"ok":true,"version":"0.4.0"}
```

验证 API Key：

```bash
curl --fail --show-error \
  -H 'Authorization: Bearer <API_KEY>' \
  https://muse.litemall.asia/v1/models
```

确认现有服务未受影响：

```bash
sudo docker ps --filter name=new-api --filter name=mysql8 --filter name=redis6
```

## 7. 日常命令

```bash
# 查看状态
sudo bash ~/deploy-muse2api.sh status

# 查看日志
sudo bash ~/deploy-muse2api.sh logs

# 重启 muse2api
sudo bash ~/deploy-muse2api.sh restart

# 停止 muse2api
sudo bash ~/deploy-muse2api.sh stop

# 拉取最新源码、重新构建并替换 muse2api
sudo bash ~/deploy-muse2api.sh update
```

这些命令都不会操作 `new-api`、MySQL 或 Redis。

## 8. 使用服务器上的本地源码

如果服务器不能访问 GitHub，可以先把源码上传到 `/data/muse2api/src`，然后执行：

```bash
sudo SOURCE_MODE=local \
  SOURCE_DIR=/data/muse2api/src \
  bash ~/deploy-muse2api.sh start
```

更新本地源码后使用相同变量执行 `update`。

如果服务器已有本机 HTTP 代理（例如 `mihomo` 监听 `127.0.0.1:7890`），可加速首次构建：

```bash
sudo SOURCE_MODE=local \
  SOURCE_DIR=/data/muse2api/src \
  BUILD_NETWORK=host \
  BUILD_PROXY=http://127.0.0.1:7890 \
  BUILD_APT_MIRROR=http://mirrors.cloud.tencent.com/debian \
  BUILD_APT_SECURITY_MIRROR=http://mirrors.cloud.tencent.com/debian-security \
  bash ~/deploy-muse2api.sh start
```

## 9. 常见问题

### Caddyfile 不在默认目录

脚本通常可以从 Caddy 容器挂载信息中自动识别。如果无法识别，可以显式指定：

```bash
sudo CADDYFILE_HOST=/data/caddy/Caddyfile \
  bash ~/deploy-muse2api.sh start
```

### 容器启动失败

```bash
sudo docker logs --tail 200 muse2api
```

重点检查 `/data/muse2api/.env`、账户配置、浏览器代理和服务器内存。

### HTTPS 暂时不可用

确认：

- `muse.litemall.asia` 已解析到服务器公网 IP。
- 云安全组已放行 80 和 443。
- Caddy 容器正在运行并已接入 `newapi-net`。
- `sudo bash ~/deploy-muse2api.sh status` 显示容器健康。
