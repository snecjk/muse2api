## 背景与原因

`muse2api` 目前只能在本地使用，需要把它作为一个新的 Docker 应用部署到现有服务器，并通过 `https://muse.litemall.asia` 对外开放。

## 变更内容

- 新增一个简单部署脚本，在服务器上构建并运行 `muse2api` 容器。
- 将容器加入服务器现有的 `newapi-net` Docker 网络。
- 将运行数据保存到独立的 `/data/muse2api/data` 目录。
- 在现有 Caddy 中增加 `muse.litemall.asia`，反向代理到 `muse2api:18610`。
- 不修改、不停止现有的 `new-api`、MySQL 和 Redis。
- 提供启动、停止、重启、状态、日志和更新命令。

## 能力范围

### 新增能力

- `public-service-deployment`：在现有服务器 Docker 环境中运行独立的 `muse2api` 应用，并通过 HTTPS 域名对外提供服务。

### 修改能力

无。

## 影响范围

- 新增 `muse2api` Docker 容器和 `/data/muse2api` 数据目录。
- 现有 Caddy 增加一个域名配置。
- 现有应用、数据库和缓存服务保持不变。
