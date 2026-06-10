#!/usr/bin/env bash
# ============================================================
# Multi-Agent AIOps Platform - Linux/macOS launcher
# ============================================================
# Startup order:
#   1. Start / check Milvus container
#   2. Start / check Redis container (RAG Chat session memory)
#   3. Start open-webSearch (Docker, fallback to npm)
#   4. Start MCP servers in background
#   5. Start FastAPI by uvicorn in foreground
#
# Usage:
#   ./run.sh
#   ./run.sh --no-mcp
#   ./run.sh --no-milvus
#   ./run.sh --no-redis
#   ./run.sh --no-websearch
#   ./run.sh --stop
# ============================================================

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$PROJECT_ROOT/logs"
mkdir -p "$LOG_DIR"

NO_MCP=false
NO_MILVUS=false
NO_REDIS=false
NO_WEBSEARCH=false
STOP=false

usage() {
  cat <<'EOF'
Usage: ./run.sh [OPTIONS]

Options:
  --stop, -Stop           Stop project services
  --no-mcp, -NoMcp        Skip MCP server auto-start
  --no-milvus, -NoMilvus  Skip Milvus auto-start
  --no-redis, -NoRedis    Skip Redis auto-start
  --no-websearch, -NoWebSearch
                          Skip open-webSearch auto-start
  -h, --help              Show this help
EOF
}

log_info()    { printf '\033[36m%s\033[0m\n' "$*"; }
log_ok()      { printf '\033[32m%s\033[0m\n' "$*"; }
log_warn()    { printf '\033[33m%s\033[0m\n' "$*"; }
log_error()   { printf '\033[31m%s\033[0m\n' "$*"; }
log_skip()    { printf '\033[33m%s\033[0m\n' "$*"; }
log_stop()    { printf '\033[33m%s\033[0m\n' "$*"; }
log_start()   { printf '\033[36m%s\033[0m\n' "$*"; }
log_ready()   { printf '\033[32m%s\033[0m\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop|-Stop) STOP=true ;;
    --no-mcp|-NoMcp) NO_MCP=true ;;
    --no-milvus|-NoMilvus) NO_MILVUS=true ;;
    --no-redis|-NoRedis) NO_REDIS=true ;;
    --no-websearch|-NoWebSearch) NO_WEBSEARCH=true ;;
    -h|--help) usage; exit 0 ;;
    *)
      log_error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

get_env_value() {
  local name="$1"
  local default_value="${2:-}"
  local env_file="$PROJECT_ROOT/.env"
  local line value

  if [[ ! -f "$env_file" ]]; then
    echo "$default_value"
    return
  fi

  line="$(grep -E "^[[:space:]]*${name}[[:space:]]*=" "$env_file" | head -n1 || true)"
  if [[ -z "$line" ]]; then
    echo "$default_value"
    return
  fi

  value="${line#*=}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"

  echo "$value"
}

test_tcp_port() {
  local host="$1"
  local port="$2"
  (echo >/dev/tcp/"$host"/"$port") >/dev/null 2>&1
}

wait_tcp_port() {
  local name="$1"
  local host="$2"
  local port="$3"
  local timeout_sec="${4:-30}"
  local deadline=$((SECONDS + timeout_sec))

  while (( SECONDS < deadline )); do
    if test_tcp_port "$host" "$port"; then
      log_ready "[ready] $name is listening on $host:$port"
      return 0
    fi
    sleep 1
  done

  log_warn "[warn] $name did not become ready on $host:$port within ${timeout_sec}s"
  return 1
}

get_port_from_url() {
  local url="$1"
  local default_port="${2:-3210}"

  if [[ "$url" =~ :([0-9]+)(/|$) ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi

  echo "$default_port"
}

test_docker_compose() {
  docker compose version >/dev/null 2>&1
}

get_npm_command() {
  if command -v npm >/dev/null 2>&1; then
    command -v npm
    return 0
  fi
  return 1
}

invoke_npm() {
  local working_directory="$1"
  local name="$2"
  shift 2
  local npm_cmd

  if ! npm_cmd="$(get_npm_command)"; then
    log_warn "[warn] npm not found. Skip $name."
    return 1
  fi

  log_start "[run] npm $* ($name)..."
  if (cd "$working_directory" && "$npm_cmd" "$@"); then
    return 0
  fi

  log_warn "[warn] npm command failed for $name"
  return 1
}

resolve_python() {
  if [[ -n "${CONDA_PREFIX:-}" && -x "$CONDA_PREFIX/bin/python" ]]; then
    echo "$CONDA_PREFIX/bin/python"
  elif [[ -x "$PROJECT_ROOT/.venv/bin/python" ]]; then
    echo "$PROJECT_ROOT/.venv/bin/python"
  else
    echo "python"
  fi
}

start_python_server() {
  local name="$1"
  local script="$2"
  local port="$3"
  local base out_log err_log

  if [[ ! -f "$script" ]]; then
    log_skip "[skip] $name script not found: $script"
    return
  fi

  if test_tcp_port "127.0.0.1" "$port"; then
    log_skip "[skip] $name already listening on port $port"
    return
  fi

  base="$(basename "$script" .py)"
  out_log="$LOG_DIR/${base}.out.log"
  err_log="$LOG_DIR/${base}.err.log"

  log_start "[start] MCP $name (port $port)..."
  (
    cd "$PROJECT_ROOT" || exit 1
    nohup "$PYTHON" "$script" >"$out_log" 2>"$err_log" &
  )

  if ! wait_tcp_port "MCP $name" "127.0.0.1" "$port" 25; then
    log_warn "       stdout: $out_log"
    log_warn "       stderr: $err_log"
  fi
}

start_open_websearch_docker() {
  local port="$1"
  local old_open_websearch_port="${OPEN_WEBSEARCH_PORT:-}"

  if ! test_docker_compose; then
    log_warn "[warn] Docker Compose is not available. Try local npm fallback for open-webSearch."
    return 1
  fi

  export OPEN_WEBSEARCH_PORT="$port"
  log_start "[build] docker compose build --progress plain open-websearch..."
  if ! (cd "$PROJECT_ROOT" && docker compose build --progress plain open-websearch); then
    log_warn "[warn] docker compose build failed for open-webSearch"
    if [[ -n "$old_open_websearch_port" ]]; then
      export OPEN_WEBSEARCH_PORT="$old_open_websearch_port"
    else
      unset OPEN_WEBSEARCH_PORT
    fi
    return 1
  fi

  log_start "[start] docker compose up -d --no-build open-websearch..."
  if ! (cd "$PROJECT_ROOT" && docker compose up -d --no-build open-websearch); then
    log_warn "[warn] docker compose up failed for open-webSearch"
    if [[ -n "$old_open_websearch_port" ]]; then
      export OPEN_WEBSEARCH_PORT="$old_open_websearch_port"
    else
      unset OPEN_WEBSEARCH_PORT
    fi
    return 1
  fi

  if [[ -n "$old_open_websearch_port" ]]; then
    export OPEN_WEBSEARCH_PORT="$old_open_websearch_port"
  else
    unset OPEN_WEBSEARCH_PORT
  fi

  wait_tcp_port "open-webSearch" "127.0.0.1" "$port" 120
}

start_open_websearch_daemon() {
  local open_websearch_root="$PROJECT_ROOT/open-webSearch-main"
  local base_url port node_modules entry npm_cmd out_log err_log

  if [[ ! -f "$open_websearch_root/package.json" ]]; then
    log_skip "[skip] open-webSearch project not found: $open_websearch_root"
    return
  fi

  base_url="$(get_env_value OPEN_WEBSEARCH_BASE_URL "http://127.0.0.1:3210")"
  port="$(get_port_from_url "$base_url" 3210)"

  if test_tcp_port "127.0.0.1" "$port"; then
    log_skip "[skip] open-webSearch already listening on port $port"
    return
  fi

  if start_open_websearch_docker "$port"; then
    return
  fi

  log_warn "[warn] Falling back to local npm for open-webSearch."

  node_modules="$open_websearch_root/node_modules"
  if [[ ! -d "$node_modules" ]]; then
    if ! invoke_npm "$open_websearch_root" "open-webSearch install" ci; then
      log_warn "[warn] open-webSearch dependencies missing. Run npm ci in $open_websearch_root."
      return
    fi
  fi

  entry="$open_websearch_root/build/index.js"
  if [[ ! -f "$entry" ]]; then
    if ! invoke_npm "$open_websearch_root" "open-webSearch build" run build; then
      log_warn "[warn] open-webSearch build missing. Run npm run build in $open_websearch_root."
      return
    fi
  fi

  if ! npm_cmd="$(get_npm_command)"; then
    log_warn "[warn] npm not found. Skip open-webSearch daemon."
    return
  fi

  out_log="$LOG_DIR/open-websearch.out.log"
  err_log="$LOG_DIR/open-websearch.err.log"
  log_start "[start] open-webSearch daemon (port $port)..."
  (
    cd "$open_websearch_root" || exit 1
    nohup "$npm_cmd" run serve -- --host 127.0.0.1 --port "$port" >"$out_log" 2>"$err_log" &
  )

  if ! wait_tcp_port "open-webSearch" "127.0.0.1" "$port" 30; then
    log_warn "       stdout: $out_log"
    log_warn "       stderr: $err_log"
  fi
}

stop_open_websearch_docker() {
  if ! test_docker_compose; then
    return
  fi

  if (cd "$PROJECT_ROOT" && docker compose stop open-websearch >/dev/null 2>&1); then
    log_stop "[stop] docker compose service open-websearch"
  fi
}

stop_port_process() {
  local port="$1"
  local pids pid comm

  if command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
  elif command -v fuser >/dev/null 2>&1; then
    pids="$(fuser -n tcp "$port" 2>/dev/null | tr -s ' ' '\n' | sed 's/[^0-9]//g' || true)"
  else
    log_warn "[warn] lsof/fuser not found, skip stopping port $port"
    return
  fi

  for pid in $pids; do
    [[ -z "$pid" || "$pid" == "$$" ]] && continue
    comm="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
    if [[ "$comm" =~ [Dd]ocker ]]; then
      log_skip "[skip] port=$port is owned by Docker process '$comm'"
      continue
    fi
    if kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null; then
      log_stop "[stop] port=$port pid=$pid"
    fi
  done
}

test_http_ready() {
  local port="$1"
  local code

  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi

  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${port}/api/v1/health/ready" 2>/dev/null || echo "000")"
  [[ "$code" =~ ^2 ]]
}

stop_services() {
  local open_websearch_stop_port
  local pid comm cmdline

  log_warn "[stop] stopping multi_agent services..."
  stop_open_websearch_docker

  if command -v pgrep >/dev/null 2>&1; then
    while IFS= read -r pid; do
      [[ -z "$pid" || "$pid" == "$$" ]] && continue
      cmdline="$(ps -p "$pid" -o args= 2>/dev/null || true)"
      if [[ "$cmdline" == *"$PROJECT_ROOT"* || "$cmdline" == *mcp_servers* || "$cmdline" == *"uvicorn app.main:app"* ]]; then
        comm="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
        if kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null; then
          log_stop "[stop] pid=$pid ${comm:-process}"
        fi
      fi
    done < <(pgrep -f "$PROJECT_ROOT|mcp_servers|uvicorn app.main:app" 2>/dev/null || true)
  fi

  open_websearch_stop_port="$(get_port_from_url "$(get_env_value OPEN_WEBSEARCH_BASE_URL "http://127.0.0.1:3210")" 3210)"
  for port in 8005 8006 8008 8009 8011 9900 "$open_websearch_stop_port"; do
    stop_port_process "$port"
  done

  log_ok "[stop] done"
}

if [[ "$STOP" == true ]]; then
  stop_services
  exit 0
fi

PYTHON="$(resolve_python)"
log_info "[start] Python: $PYTHON"

if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
  log_error "[error] .env not found. Please create .env first."
  exit 1
fi

APP_PORT="$(get_env_value PORT "9900")"

if [[ "$NO_MILVUS" != true ]]; then
  log_info "[check] Milvus (localhost:19530)..."
  if ! test_tcp_port "127.0.0.1" 19530; then
    if test_docker_compose; then
      log_start "[start] docker compose up -d standalone..."
      if ! (cd "$PROJECT_ROOT" && docker compose up -d standalone); then
        log_warn "[warn] Docker is not available or docker compose failed. Milvus may be unavailable."
      fi
    else
      log_warn "[warn] Docker Compose is not available. Milvus may be unavailable."
    fi
  fi
  wait_tcp_port "Milvus" "127.0.0.1" 19530 90 >/dev/null || true
else
  log_skip "[skip] Milvus auto-start disabled by --no-milvus"
fi

if [[ "$NO_REDIS" != true ]]; then
  log_info "[check] Redis (localhost:6379)..."
  if ! test_tcp_port "127.0.0.1" 6379; then
    if test_docker_compose; then
      log_start "[start] docker compose up -d redis..."
      if ! (cd "$PROJECT_ROOT" && docker compose up -d redis); then
        log_warn "[warn] Docker not available or docker compose failed. Redis session memory will be disabled."
      fi
    else
      log_warn "[warn] Docker Compose is not available. Redis session memory will be disabled."
    fi
  fi

  if wait_tcp_port "Redis" "127.0.0.1" 6379 30; then
    mem_flag="$(get_env_value RAG_CHAT_MEMORY_ENABLED "false")"
    if [[ ! "$mem_flag" =~ ^[Tt][Rr][Uu][Ee]$ ]]; then
      log_warn "[hint] Redis running, but .env RAG_CHAT_MEMORY_ENABLED=$mem_flag. Set it to 'true' to enable session memory."
    fi
  fi
else
  log_skip "[skip] Redis auto-start disabled by --no-redis"
fi

if [[ "$NO_WEBSEARCH" != true ]]; then
  start_open_websearch_daemon
else
  log_skip "[skip] open-webSearch auto-start disabled by --no-websearch"
fi

if [[ "$NO_MCP" != true ]]; then
  start_python_server "system_server" "$PROJECT_ROOT/mcp_servers/system_server.py" 8005
  start_python_server "websearch_server" "$PROJECT_ROOT/mcp_servers/websearch_server.py" 8006
  start_python_server "winlog_server" "$PROJECT_ROOT/mcp_servers/winlog_server.py" 8008
  start_python_server "network_server" "$PROJECT_ROOT/mcp_servers/network_server.py" 8009
  start_python_server "docker_server" "$PROJECT_ROOT/mcp_servers/docker_server.py" 8011
else
  log_skip "[skip] MCP auto-start disabled by --no-mcp"
fi

if test_tcp_port "127.0.0.1" "$APP_PORT"; then
  if test_http_ready "$APP_PORT"; then
    log_ok "[ready] FastAPI main service is already running on port $APP_PORT"
    log_ok "        Web UI:  http://localhost:$APP_PORT"
    log_ok "        API Doc: http://localhost:$APP_PORT/docs"
    exit 0
  fi
  log_warn "[warn] port $APP_PORT is already in use, but health check failed."
  log_warn "       Close the old terminal/window, or run: ./run.sh --stop"
  exit 1
fi

log_ok "[start] FastAPI main service (port $APP_PORT)..."
log_ok "        Web UI:  http://localhost:$APP_PORT"
log_ok "        API Doc: http://localhost:$APP_PORT/docs"
echo ""

cd "$PROJECT_ROOT"
exec "$PYTHON" -m uvicorn app.main:app \
  --host 0.0.0.0 \
  --port "$APP_PORT" \
  --reload \
  --reload-dir "$PROJECT_ROOT/app"
