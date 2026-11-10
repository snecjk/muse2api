## 1. 部署脚本

- [x] 1.1 创建 `deploy/china/deploy-muse2api.sh`，定义镜像、容器、数据目录、环境文件、网络和域名配置。
- [x] 1.2 实现 Docker 镜像构建和 `muse2api` 容器创建，加入 `newapi-net` 并挂载持久化数据目录。
- [x] 1.3 实现 `start`、`stop`、`restart`、`status`、`logs` 和 `update` 命令。
- [x] 1.4 加入 `/healthz` 检查，启动失败时输出容器日志。

## 2. Caddy 与公网域名

- [x] 2.1 在脚本中增加 `muse.litemall.asia` Caddy 配置，修改前备份并在校验成功后 reload。
- [x] 2.2 确保重复执行脚本不会重复添加域名配置，也不会覆盖现有 Caddy 站点。

## 3. 文档与验证

- [x] 3.1 简化并更新 `docs/DEPLOY_PUBLIC.md`，说明环境文件、数据上传、脚本命令和 DNS 配置。
- [x] 3.2 验证容器健康、HTTPS、API Key、数据持久化，以及现有 `new-api`、MySQL 和 Redis 未受影响。
