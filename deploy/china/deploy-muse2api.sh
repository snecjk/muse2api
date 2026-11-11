#!/usr/bin/env bash
# 在现有 new-api 服务器上部署独立的 muse2api 容器。
# 只操作 muse2api 和它自己的 Caddy 配置块，不操作 new-api/mysql8/redis6。

set -euo pipefail

# ---------------- 可配置项 ----------------
MUSE_IMAGE="${MUSE_IMAGE:-muse2api:latest}"
MUSE_CONTAINER="${MUSE_CONTAINER:-muse2api}"
REPO_URL="${REPO_URL:-https://github.com/snecjk/muse2api.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
SOURCE_MODE="${SOURCE_MODE:-git}" # git | local

BASE_DIR="${BASE_DIR:-/data/muse2api}"
SOURCE_DIR="${SOURCE_DIR:-${BASE_DIR}/src}"
DATA_DIR="${DATA_DIR:-${BASE_DIR}/data}"
ENV_FILE="${ENV_FILE:-${BASE_DIR}/.env}"

SHARED_NETWORK="${SHARED_NETWORK:-newapi-net}"
DOMAIN="${DOMAIN:-muse.litemall.asia}"
INTERNAL_PORT="${INTERNAL_PORT:-18610}"

CADDY_CONTAINER="${CADDY_CONTAINER:-caddy}"
CADDYFILE_HOST="${CADDYFILE_HOST:-}"
CADDYFILE_FALLBACK="${CADDYFILE_FALLBACK:-/data/caddy/Caddyfile}"

HEALTH_WAIT_ROUNDS="${HEALTH_WAIT_ROUNDS:-30}"
HEALTH_WAIT_INTERVAL="${HEALTH_WAIT_INTERVAL:-2}"
# 国内服务器构建较慢时可设置：
# BUILD_NETWORK=host BUILD_PROXY=http://127.0.0.1:7890
BUILD_NETWORK="${BUILD_NETWORK:-}"
BUILD_PROXY="${BUILD_PROXY:-}"
BUILD_APT_MIRROR="${BUILD_APT_MIRROR:-}"
BUILD_APT_SECURITY_MIRROR="${BUILD_APT_SECURITY_MIRROR:-}"
# The runtime browser proxy is separate from the Docker build proxy. A proxy on
# the host must be addressed through Docker's host gateway, not 127.0.0.1.
RUNTIME_BROWSER_PROXY="${RUNTIME_BROWSER_PROXY:-}"
# ------------------------------------------

MANAGED_BEGIN="# BEGIN MUSE2API MANAGED"
MANAGED_END="# END MUSE2API MANAGED"

log()  { printf '\033[34m[%s]\033[0m %s\n' "$(date '+%H:%M:%S')" "$*"; }
ok()   { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    err "请以 root 身份运行：sudo bash $0 <command>"
    exit 1
  fi
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    err "未找到 docker。"
    exit 1
  fi
}

container_exists() {
  docker ps -a --format '{{.Names}}' | grep -Fxq "${MUSE_CONTAINER}"
}

container_running() {
  docker ps --format '{{.Names}}' | grep -Fxq "${MUSE_CONTAINER}"
}

ensure_network() {
  if ! docker network ls --format '{{.Name}}' | grep -Fxq "${SHARED_NETWORK}"; then
    err "Docker 网络 ${SHARED_NETWORK} 不存在；请先确认现有 new-api 服务网络。"
    exit 1
  fi
}

ensure_directories() {
  mkdir -p "${BASE_DIR}" "${DATA_DIR}"
  chown -R 1000:1000 "${DATA_DIR}"
}

validate_env_file() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    err "生产环境文件不存在：${ENV_FILE}"
    err "请先参考 .env.example 创建并设置 API Key。"
    exit 1
  fi
  chmod 600 "${ENV_FILE}"
}

sync_source() {
  if [[ "${SOURCE_MODE}" == "local" ]]; then
    if [[ ! -f "${SOURCE_DIR}/Dockerfile" ]]; then
      err "SOURCE_MODE=local，但 ${SOURCE_DIR}/Dockerfile 不存在。"
      exit 1
    fi
    log "使用服务器现有源码：${SOURCE_DIR}"
    return
  fi

  if [[ "${SOURCE_MODE}" != "git" ]]; then
    err "SOURCE_MODE 只支持 git 或 local。"
    exit 1
  fi
  if ! command -v git >/dev/null 2>&1; then
    err "SOURCE_MODE=git 需要安装 git。"
    exit 1
  fi

  if [[ -d "${SOURCE_DIR}/.git" ]]; then
    log "更新 muse2api 源码..."
    git -C "${SOURCE_DIR}" fetch --quiet origin "${REPO_BRANCH}"
    git -C "${SOURCE_DIR}" reset --hard --quiet "origin/${REPO_BRANCH}"
    git -C "${SOURCE_DIR}" clean -fd --quiet
  else
    if [[ -e "${SOURCE_DIR}" ]] && [[ -n "$(find "${SOURCE_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
      err "源码目录非空且不是 Git 仓库：${SOURCE_DIR}"
      exit 1
    fi
    mkdir -p "$(dirname "${SOURCE_DIR}")"
    log "克隆 muse2api 源码..."
    git clone --branch "${REPO_BRANCH}" --single-branch --depth 1 \
      "${REPO_URL}" "${SOURCE_DIR}"
  fi
  ok "源码版本：$(git -C "${SOURCE_DIR}" log -1 --format='%h %s')"
}

build_image() {
  local build_args=()
  if [[ -n "${BUILD_NETWORK}" ]]; then
    build_args+=(--network "${BUILD_NETWORK}")
  fi
  if [[ -n "${BUILD_PROXY}" ]]; then
    build_args+=(
      --build-arg "HTTP_PROXY=${BUILD_PROXY}"
      --build-arg "HTTPS_PROXY=${BUILD_PROXY}"
      --build-arg "http_proxy=${BUILD_PROXY}"
      --build-arg "https_proxy=${BUILD_PROXY}"
    )
  fi
  if [[ -n "${BUILD_APT_MIRROR}" ]]; then
    build_args+=(--build-arg "APT_MIRROR=${BUILD_APT_MIRROR}")
  fi
  if [[ -n "${BUILD_APT_SECURITY_MIRROR}" ]]; then
    build_args+=(--build-arg "APT_SECURITY_MIRROR=${BUILD_APT_SECURITY_MIRROR}")
  fi
  log "构建镜像 ${MUSE_IMAGE}..."
  docker build "${build_args[@]}" -t "${MUSE_IMAGE}" "${SOURCE_DIR}"
  ok "镜像构建完成。"
}

create_container() {
  local runtime_args=()
  if [[ -n "${RUNTIME_BROWSER_PROXY}" ]]; then
    runtime_args+=(
      --add-host host.docker.internal:host-gateway
      -e "MUSE2API_BROWSER_PROXY=${RUNTIME_BROWSER_PROXY}"
    )
  fi
  log "启动容器 ${MUSE_CONTAINER}..."
  docker run -d \
    --name "${MUSE_CONTAINER}" \
    --restart unless-stopped \
    --network "${SHARED_NETWORK}" \
    --env-file "${ENV_FILE}" \
    -e MUSE2API_HOST=0.0.0.0 \
    -e "MUSE2API_PORT=${INTERNAL_PORT}" \
    -e MUSE2API_DATA_DIR=/app/data \
    -e "MUSE2API_PUBLIC_BASE=https://${DOMAIN}" \
    "${runtime_args[@]}" \
    -v "${DATA_DIR}:/app/data" \
    --shm-size 1g \
    "${MUSE_IMAGE}" >/dev/null
}

health_check() {
  docker exec "${MUSE_CONTAINER}" python -c \
    "import json, urllib.request; d=json.load(urllib.request.urlopen('http://127.0.0.1:${INTERNAL_PORT}/healthz', timeout=5)); raise SystemExit(0 if d.get('ok') is True else 1)" \
    >/dev/null 2>&1
}

wait_healthy() {
  log "等待 muse2api 健康检查（最多 $((HEALTH_WAIT_ROUNDS * HEALTH_WAIT_INTERVAL)) 秒）..."
  local round=0
  until health_check; do
    round=$((round + 1))
    if (( round >= HEALTH_WAIT_ROUNDS )); then
      err "muse2api 未在预期时间内通过 /healthz。"
      docker logs --tail 100 "${MUSE_CONTAINER}" >&2 || true
      return 1
    fi
    sleep "${HEALTH_WAIT_INTERVAL}"
  done
  ok "muse2api 健康检查通过。"
}

check_upstream_network() {
  log "检查容器到 muse.ai 的运行时网络..."
  if docker exec "${MUSE_CONTAINER}" python -c '
import os, urllib.error, urllib.request
proxy = os.environ.get("MUSE2API_BROWSER_PROXY", "").strip()
handler = urllib.request.ProxyHandler({"http": proxy, "https": proxy}) if proxy else urllib.request.ProxyHandler({})
request = urllib.request.Request("https://muse.ai/thread/new", method="HEAD", headers={"User-Agent": "Mozilla/5.0"})
try:
    response = urllib.request.build_opener(handler).open(request, timeout=15)
except urllib.error.HTTPError as error:
    # A 401/403 still proves that DNS, proxy CONNECT and TLS all worked.
    response = error
with response:
    if response.status >= 500:
        raise SystemExit(1)
' >/dev/null 2>&1; then
    ok "容器可访问 muse.ai。"
  else
    err "容器无法访问 muse.ai；/healthz 虽正常，聊天仍会 500/504。"
    err "请检查 MUSE2API_BROWSER_PROXY 和代理节点状态。"
    return 1
  fi
}

resolve_caddyfile() {
  if [[ -n "${CADDYFILE_HOST}" ]]; then
    return
  fi
  CADDYFILE_HOST="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' "${CADDY_CONTAINER}" 2>/dev/null || true)"
  if [[ -z "${CADDYFILE_HOST}" ]]; then
    CADDYFILE_HOST="${CADDYFILE_FALLBACK}"
  fi
}

configure_caddy() {
  if ! docker ps --format '{{.Names}}' | grep -Fxq "${CADDY_CONTAINER}"; then
    err "Caddy 容器未运行：${CADDY_CONTAINER}"
    return 1
  fi

  resolve_caddyfile
  if [[ ! -f "${CADDYFILE_HOST}" ]]; then
    err "找不到 Caddyfile：${CADDYFILE_HOST}"
    return 1
  fi

  local begin_count end_count candidate backup caddy_image
  begin_count="$(grep -Fxc "${MANAGED_BEGIN}" "${CADDYFILE_HOST}" || true)"
  end_count="$(grep -Fxc "${MANAGED_END}" "${CADDYFILE_HOST}" || true)"
  if [[ "${begin_count}" != "${end_count}" ]] || (( begin_count > 1 )); then
    err "Caddyfile 中的 muse2api 受控区块标记异常，请先人工检查。"
    return 1
  fi

  candidate="$(mktemp "${CADDYFILE_HOST}.candidate.XXXXXX")"
  backup="${CADDYFILE_HOST}.bak.$(date '+%Y%m%d%H%M%S')"

  awk -v begin="${MANAGED_BEGIN}" -v end="${MANAGED_END}" '
    $0 == begin { skip=1; next }
    $0 == end   { skip=0; next }
    !skip       { print }
  ' "${CADDYFILE_HOST}" > "${candidate}"
  cat >> "${candidate}" <<EOF

${MANAGED_BEGIN}
${DOMAIN} {
    encode gzip zstd
    reverse_proxy ${MUSE_CONTAINER}:${INTERNAL_PORT} {
        # 立即向客户端刷新 SSE 数据，避免等待完整回答后一次性返回。
        flush_interval -1
    }
}
${MANAGED_END}
EOF

  caddy_image="$(docker inspect --format '{{.Config.Image}}' "${CADDY_CONTAINER}")"
  log "校验 Caddy 配置..."
  if ! docker run --rm \
      --network "${SHARED_NETWORK}" \
      -v "${candidate}:/etc/caddy/Caddyfile:ro" \
      --entrypoint caddy \
      "${caddy_image}" \
      validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null; then
    rm -f "${candidate}"
    err "Caddy 候选配置校验失败，现有配置未修改。"
    return 1
  fi

  cp -a "${CADDYFILE_HOST}" "${backup}"
  cat "${candidate}" > "${CADDYFILE_HOST}"
  if ! docker exec "${CADDY_CONTAINER}" \
      caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile; then
    err "Caddy reload 失败，恢复原配置。"
    cat "${backup}" > "${CADDYFILE_HOST}"
    docker exec "${CADDY_CONTAINER}" \
      caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile || true
    rm -f "${candidate}"
    return 1
  fi
  rm -f "${candidate}"
  ok "Caddy 已加载 https://${DOMAIN}，备份：${backup}"
}

cmd_start() {
  ensure_network
  ensure_directories
  validate_env_file

  if container_running; then
    ok "${MUSE_CONTAINER} 已在运行。"
    wait_healthy
    check_upstream_network
    configure_caddy
    return
  fi
  if container_exists; then
    docker start "${MUSE_CONTAINER}" >/dev/null
  else
    sync_source
    build_image
    create_container
  fi
  wait_healthy
  check_upstream_network
  configure_caddy
}

cmd_stop() {
  if ! container_exists; then
    warn "${MUSE_CONTAINER} 容器不存在。"
    return
  fi
  if container_running; then
    docker stop "${MUSE_CONTAINER}" >/dev/null
    ok "${MUSE_CONTAINER} 已停止。"
  else
    warn "${MUSE_CONTAINER} 已处于停止状态。"
  fi
}

cmd_restart() {
  if ! container_exists; then
    cmd_start
    return
  fi
  docker restart "${MUSE_CONTAINER}" >/dev/null
  wait_healthy
  check_upstream_network
  configure_caddy
}

cmd_status() {
  docker ps -a --filter "name=^${MUSE_CONTAINER}$" \
    --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Networks}}'
  if container_running && health_check; then
    ok "容器内部 /healthz 正常。"
  else
    warn "容器未运行或 /healthz 异常。"
  fi
  if command -v curl >/dev/null 2>&1 && curl -fsS -m 10 "https://${DOMAIN}/healthz" >/dev/null; then
    ok "https://${DOMAIN}/healthz 正常。"
  else
    warn "公网 HTTPS 尚未通过检查。"
  fi
  log "现有服务状态（只读）："
  docker ps -a --filter name=new-api --filter name=mysql8 --filter name=redis6 \
    --format 'table {{.Names}}\t{{.Status}}' || true
}

cmd_logs() {
  if ! container_exists; then
    err "${MUSE_CONTAINER} 容器不存在。"
    exit 1
  fi
  docker logs -f --tail 200 "${MUSE_CONTAINER}"
}

cmd_update() {
  ensure_network
  ensure_directories
  validate_env_file
  sync_source
  build_image

  if container_exists; then
    docker rm -f "${MUSE_CONTAINER}" >/dev/null
  fi
  create_container
  wait_healthy
  check_upstream_network
  configure_caddy
}

usage() {
  cat <<EOF
用法：sudo bash $0 <command>

命令：
  start     构建并启动 muse2api，同时配置 Caddy
  stop      只停止 muse2api
  restart   只重启 muse2api
  status    查看容器、健康检查和现有服务状态
  logs      跟随 muse2api 日志
  update    更新源码、重建镜像并替换 muse2api

常用环境变量：
  SOURCE_MODE=git|local       源码模式，默认 git
  SOURCE_DIR=/data/...        服务器源码目录
  ENV_FILE=/data/.../.env     生产环境文件
  DOMAIN=muse.litemall.asia   公网域名
  CADDYFILE_HOST=/data/...    Caddyfile 宿主机路径（通常可自动识别）
  BUILD_NETWORK=host          Docker 构建网络（可选）
  BUILD_PROXY=http://...      Docker 构建 HTTP/HTTPS 代理（可选）
  RUNTIME_BROWSER_PROXY=...   Chromium 运行时代理（可选）
  BUILD_APT_MIRROR=http://... Debian 软件源镜像（可选）
EOF
}

case "${1:-}" in
  start|stop|restart|status|logs|update)
    require_root
    require_docker
    "cmd_${1}"
    ;;
  -h|--help|help|"") usage ;;
  *) err "未知命令：$1"; usage; exit 1 ;;
esac
