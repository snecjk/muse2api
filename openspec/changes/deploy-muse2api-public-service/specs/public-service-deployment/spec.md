## ADDED Requirements

### Requirement: 独立运行 muse2api
部署脚本必须（MUST）在现有服务器中创建独立的 `muse2api` Docker 容器，将其加入 `newapi-net`，并挂载 `/data/muse2api/data` 保存运行数据。

#### Scenario: 启动应用
- **WHEN** 运维人员执行部署脚本的 `start` 命令
- **THEN** 系统必须构建并启动 `muse2api` 容器，且不得停止或重启其他容器

### Requirement: 通过 HTTPS 对外开放
部署方案必须（MUST）通过现有 Caddy 将 `https://muse.litemall.asia` 反向代理到 `muse2api:18610`。

#### Scenario: 访问公网健康接口
- **WHEN** 用户访问 `https://muse.litemall.asia/healthz`
- **THEN** Caddy 必须把请求转发给 `muse2api` 并返回健康响应

### Requirement: 保留运行数据
部署方案必须（MUST）在重启或更新容器后保留 `/data/muse2api/data` 中的账户、密钥、浏览器状态和请求数据。

#### Scenario: 更新容器
- **WHEN** 运维人员执行 `update` 重新构建容器
- **THEN** 新容器必须继续挂载原数据目录并加载原有运行状态

### Requirement: 不影响现有服务
部署脚本不得（MUST NOT）停止、删除或重建 `new-api`、`mysql8` 和 `redis6`。

#### Scenario: 部署完成
- **WHEN** `muse2api` 部署或更新完成
- **THEN** 服务器原有应用和数据服务必须继续保持运行
