#!/usr/bin/env bash
#
# dev-up.sh - start the AgentScope Service stack locally.
#
#   Gateway    :18080
#   aistiod    :8081  (Go control plane: /api/*, /api/v1/*, console SPA)
#   Data       :8082
#   Scheduler  :8083
#   Postgres   :5432  (schemas cp + rt + dp; via Docker)
#
# aistiod runs standalone here (AISTIO_ENABLE_KUBERNETES=false), so no
# reconcilers, CRD-backed APIs, or ASDP gRPC listener are started.
#
# Usage:
#   scripts/dev-up.sh
#   BUILDER_REBUILD=1 scripts/dev-up.sh   # rebuild binaries and reset the disposable dev schemas
#   BUILDER_REBUILD=1 BUILDER_RESET_DB=0 scripts/dev-up.sh  # rebuild while preserving local data
#   scripts/dev-down.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${BUILDER_RUN_DIR:-$ROOT/.dev-stack}"
LOG_DIR="$RUN_DIR/logs"
PID_DIR="$RUN_DIR/pids"
mkdir -p "$LOG_DIR" "$PID_DIR"

STARTUP_SUCCEEDED=0
cleanup_failed_startup() {
    local status=$?
    if [ "$status" -ne 0 ] && [ "$STARTUP_SUCCEEDED" != "1" ] && [ "${BUILDER_KEEP_FAILED_STACK:-0}" != "1" ]; then
        echo "==> Startup failed; stopping partially started planes" >&2
        "$ROOT/scripts/dev-down.sh" || true
    fi
}
trap cleanup_failed_startup EXIT

GATEWAY_PORT="${BUILDER_GATEWAY_PORT:-18080}"
CONTROL_PORT="${BUILDER_CONTROL_PORT:-8081}"
DATA_PORT="${BUILDER_DATA_PORT:-8082}"
SCHED_PORT="${BUILDER_SCHEDULER_PORT:-8083}"
PG_PORT="${BUILDER_PG_PORT:-5432}"
PG_CONTAINER="${BUILDER_PG_CONTAINER:-agentscope-dev-pg}"
RESET_DB="${BUILDER_RESET_DB:-${BUILDER_REBUILD:-0}}"

# jdbc profile requires >=32 chars and rejects known short defaults (see InternalTokenStartupValidator)
export BUILDER_INTERNAL_TOKEN="${BUILDER_INTERNAL_TOKEN:-local-dev-internal-token-at-least-32chars}"
export BUILDER_JWT_SECRET="${BUILDER_JWT_SECRET:-builder-default-dev-secret-change-in-production-32chars}"
export SPRING_PROFILES_ACTIVE="${SPRING_PROFILES_ACTIVE:-jdbc}"

DB_URL="jdbc:postgresql://localhost:${PG_PORT}/builder?currentSchema=dp"
AISTIO_DSN="postgres://builder:builder@localhost:${PG_PORT}/builder?sslmode=disable"
AISTIO_RUNTIME_DSN="${AISTIO_DSN}&search_path=rt"

jar_of() {
    find "$ROOT/$1/target" -maxdepth 1 -name "$1-*.jar" \
        ! -name "*sources*" ! -name "*javadoc*" | head -1
}

managed_plane_name() {
    local pid="$1" command
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [ -n "$command" ] || return 1
    case "$command" in
        *"$ROOT/aistio/bin/aistiod"*) echo control ;;
        *"$ROOT/service-dataplane/target/service-dataplane-"*.jar*) echo data ;;
        *"$ROOT/service-scheduler/target/service-scheduler-"*.jar*) echo scheduler ;;
        *"$ROOT/service-gateway/target/service-gateway-"*.jar*) echo gateway ;;
        *) return 1 ;;
    esac
}

describe_pid() {
    local pid="$1" command
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [ -n "$command" ] || command="<process exited>"
    echo "pid ${pid}: ${command}"
}

stop_managed_pid() {
    local port="$1" pid="$2" plane
    plane="$(managed_plane_name "$pid")" || return 1
    echo "  * freeing :${port} from stale ${plane} plane (pid ${pid})"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 10); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 1
    done
    kill -9 "$pid" 2>/dev/null || true
}

free_port() {
    local port="$1" pids pid blocked=0
    pids="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
    [ -n "$pids" ] || return 0
    for pid in $pids; do
        if managed_plane_name "$pid" >/dev/null; then
            stop_managed_pid "$port" "$pid"
        else
            echo "  ERROR :${port} is already in use ($(describe_pid "$pid"))" >&2
            blocked=1
        fi
    done
    [ "$blocked" = "0" ]
}

ensure_service_ports_available() {
    local blocked=0 port
    for port in "$GATEWAY_PORT" "$CONTROL_PORT" "$DATA_PORT" "$SCHED_PORT"; do
        free_port "$port" || blocked=1
    done
    if [ "$blocked" != "0" ]; then
        echo "Another application or Docker container owns an AgentScope Service port." >&2
        echo "Stop that workload or override BUILDER_GATEWAY_PORT/CONTROL_PORT/DATA_PORT/SCHEDULER_PORT." >&2
        return 1
    fi
}

wait_health() {
    local name="$1" port="$2" timeout="${3:-90}" path="${4:-/actuator/health}" i
    for i in $(seq 1 "$timeout"); do
        if curl -sf -m 2 "http://localhost:${port}${path}" >/dev/null 2>&1; then
            echo "  OK ${name} healthy on :${port}"
            return 0
        fi
        sleep 1
    done
    echo "  FAIL ${name} did not become healthy within ${timeout}s - see ${LOG_DIR}/${name}.log" >&2
    return 1
}

start() {
    local name="$1" pidfile="$2" pid plane; shift 2
    mkdir -p "$LOG_DIR" "$PID_DIR"
    if [ -f "$pidfile" ]; then
        pid="$(cat "$pidfile")"
        if kill -0 "$pid" 2>/dev/null; then
            if plane="$(managed_plane_name "$pid")" && [ "$plane" = "$name" ]; then
                echo "  * ${name} already running (pid ${pid})"
                return 0
            fi
            echo "  * ignoring stale ${name} PID file ($(describe_pid "$pid"))" >&2
        fi
        rm -f "$pidfile"
    fi
    # Detach into a new session so planes survive after this script (and Cursor/CI
    # wrappers) exit. macOS has no setsid(1); python3 is available on the supported
    # local toolchain.
    python3 - "$LOG_DIR/${name}.log" "$@" <<'PY' &
import os, sys
log_path = sys.argv[1]
argv = sys.argv[2:]
os.makedirs(os.path.dirname(log_path) or ".", exist_ok=True)
os.setsid()
log = open(log_path, "wb")
os.dup2(log.fileno(), 1)
os.dup2(log.fileno(), 2)
devnull = open(os.devnull, "rb")
os.dup2(devnull.fileno(), 0)
os.execvpe(argv[0], argv, os.environ)
PY
    echo $! >"$pidfile"
    echo "  * ${name} started (pid $!)"
}

# Check before expensive builds or database changes. On macOS, Docker Desktop
# itself listens on ports published by containers, so arbitrary port-based kills
# can terminate the entire Docker engine.
ensure_service_ports_available

# ---------------------------------------------------------------- build Java
# Always install from the monorepo root (not agentscope-service/ alone):
# fat jars embed ~/.m2 harness/core/extensions; a service-only build can keep a
# stale snapshot. Root `mvn install` also walks agentscope-service children
# (unlike `-pl agentscope-service`, which only builds the packaging=pom aggregator).
if [ "${BUILDER_REBUILD:-0}" = "1" ] || [ ! -f "$(jar_of service-gateway || true)" ]; then
    echo "==> Building agentscope-java monorepo (mvn install -DskipTests)"
    MONOREPO_ROOT="$(cd "$ROOT/.." && pwd)"
    (cd "$MONOREPO_ROOT" && mvn install -DskipTests -q)
fi

# ---------------------------------------------------------------- build console
# Generated UI assets are no longer tracked; a fresh clone must build the SPA.
if [ "${BUILDER_REBUILD:-0}" = "1" ] || [ ! -f "$ROOT/aistio/ui/index.html" ]; then
    echo "==> Building console from frontend sources"
    (cd "$ROOT/frontend" && npm ci && npm run build)
fi

# ---------------------------------------------------------------- build aistiod
AISTIO_BIN="$ROOT/aistio/bin/aistiod"
if [ "${BUILDER_REBUILD:-0}" = "1" ] || [ ! -x "$AISTIO_BIN" ]; then
    echo "==> Building aistiod"
    (cd "$ROOT/aistio" && mkdir -p bin && go build -o bin/aistiod ./cmd/aistiod)
fi

# ---------------------------------------------------------------- postgres
# ---------------------------------------------------------------- postgres (local, docker-free)
PGBIN="${BUILDER_PGBIN:-$HOME/toolchain/Postgres.app/Contents/Versions/17/bin}"
PGDATA="${BUILDER_PGDATA:-$HOME/toolchain/pgdata-main}"
if ! "$PGBIN/pg_isready" -h localhost -p "$PG_PORT" >/dev/null 2>&1; then
    if [ ! -d "$PGDATA" ]; then
        echo "==> initdb ${PGDATA}"
        "$PGBIN/initdb" -D "$PGDATA" -U builder -A trust --locale=C -E UTF8 >/dev/null
    fi
    echo "==> Starting local Postgres on :${PG_PORT}"
    "$PGBIN/pg_ctl" -D "$PGDATA" -o "-p $PG_PORT -k $PGDATA" -l "$LOG_DIR/postgres.log" start >/dev/null
fi
echo "==> Waiting for Postgres"
for i in $(seq 1 30); do
    if "$PGBIN/pg_isready" -h localhost -p "$PG_PORT" >/dev/null 2>&1; then
        echo "  OK Postgres ready"; break
    fi
    sleep 1
done
"$PGBIN/psql" -h localhost -p "$PG_PORT" -U builder -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='builder'" | grep -q 1 || "$PGBIN/createdb" -h localhost -p "$PG_PORT" -U builder builder

if [ "${BUILDER_RESET_DB:-1}" = "1" ]; then
    echo "==> Resetting disposable Postgres schemas cp, rt, dp"
    "$PGBIN/psql" -h localhost -p "$PG_PORT" -U builder -d builder -v ON_ERROR_STOP=1 -c \
        "DROP SCHEMA IF EXISTS cp CASCADE; DROP SCHEMA IF EXISTS rt CASCADE; DROP SCHEMA IF EXISTS dp CASCADE;" >/dev/null
fi

"$PGBIN/psql" -h localhost -p "$PG_PORT" -U builder -d builder -v ON_ERROR_STOP=1 \
    <"$ROOT/docker/postgres-init.sql" >/dev/null

schema_count="$("$PGBIN/psql" -h localhost -p "$PG_PORT" -U builder -d builder -Atc \
    "SELECT count(*) FROM information_schema.schemata WHERE schema_name IN ('cp','rt','dp')")"
if [ "$schema_count" != "3" ]; then
    echo "Expected cp, rt, and dp schemas, found ${schema_count}" >&2
    exit 1
fi

# ---------------------------------------------------------------- planes
mkdir -p "$LOG_DIR" "$PID_DIR"

echo "==> Starting planes (Postgres: ${DB_URL})"

start control "$PID_DIR/control.pid" \
    env AISTIO_ENABLE_KUBERNETES=false \
        AISTIO_PRODUCT_DSN="$AISTIO_DSN" \
        AISTIO_HTTP_BIND=":${CONTROL_PORT}" \
        BUILDER_JWT_SECRET="$BUILDER_JWT_SECRET" \
        BUILDER_INTERNAL_TOKEN="$BUILDER_INTERNAL_TOKEN" \
        BUILDER_DATA_URL="http://localhost:${DATA_PORT}" \
        BUILDER_ALLOW_LOCAL_ENVIRONMENT=true \
        AISTIO_WORKSPACE_ROOT="$RUN_DIR/workspaces" \
        AISTIO_ARTIFACT_ROOT="$RUN_DIR/artifacts" \
        AISTIO_STATIC_DIR="$ROOT/aistio/ui" \
    "$AISTIO_BIN" \
        --storage-driver=postgres \
        --storage-dsn="$AISTIO_RUNTIME_DSN" \
        --log-format=console

start data "$PID_DIR/data.pid" \
    env BUILDER_DB_URL="$DB_URL" BUILDER_DB_DRIVER=org.postgresql.Driver \
        BUILDER_DB_USER=builder BUILDER_DB_PASSWORD=builder \
        BUILDER_DATA_PORT="$DATA_PORT" \
        BUILDER_CONTROL_URL="http://localhost:${CONTROL_PORT}" \
        BUILDER_INTERNAL_TOKEN="$BUILDER_INTERNAL_TOKEN" \
        BUILDER_JWT_SECRET="$BUILDER_JWT_SECRET" \
    java -XX:TieredStopAtLevel=1 -Xss4m -jar "$(jar_of service-dataplane)"

start scheduler "$PID_DIR/scheduler.pid" \
    env BUILDER_DB_URL="$DB_URL" BUILDER_DB_DRIVER=org.postgresql.Driver \
        BUILDER_DB_USER=builder BUILDER_DB_PASSWORD=builder \
        BUILDER_SCHEDULER_PORT="$SCHED_PORT" \
        BUILDER_CONTROL_URL="http://localhost:${CONTROL_PORT}" \
        BUILDER_DATA_URL="http://localhost:${DATA_PORT}" \
        BUILDER_INTERNAL_TOKEN="$BUILDER_INTERNAL_TOKEN" \
        BUILDER_JWT_SECRET="$BUILDER_JWT_SECRET" \
    java -jar "$(jar_of service-scheduler)"

start gateway "$PID_DIR/gateway.pid" \
    env BUILDER_GATEWAY_PORT="$GATEWAY_PORT" \
        BUILDER_CONTROL_URL="http://localhost:${CONTROL_PORT}" \
        BUILDER_DATA_URL="http://localhost:${DATA_PORT}" \
        BUILDER_SCHEDULER_URL="http://localhost:${SCHED_PORT}" \
    java -jar "$(jar_of service-gateway)"

echo "==> Waiting for health"
wait_health control "$CONTROL_PORT" 120 /healthz
wait_health data "$DATA_PORT" 300
wait_health scheduler "$SCHED_PORT" 300
wait_health gateway "$GATEWAY_PORT" 120

echo "==> Verifying database schemas and v4 terminal migrations"
"$PGBIN/psql" -h localhost -p "$PG_PORT" -U builder -d builder -v ON_ERROR_STOP=1 \
    <"$ROOT/docker/postgres-dev-verify.sql" >/dev/null
echo "  OK cp/rt/dp schemas and v4 collaboration/orchestration/runtime tables"

if [ "${BUILDER_SMOKE_TEST:-0}" = "1" ]; then
    echo "==> Running API smoke test"
    BASE="http://localhost:${GATEWAY_PORT}" "$ROOT/scripts/smoke.sh"
fi

STARTUP_SUCCEEDED=1

cat <<EOF

==> AgentScope Service stack is up (aistiod + Java DP)

  Console (SPA via gateway):  http://localhost:${GATEWAY_PORT}/
  Default login:              admin / admin

  Frontend HMR (optional):    cd frontend && npm run dev

  Logs:   ${LOG_DIR}
  Verify: scripts/smoke.sh
  Stop:   scripts/dev-down.sh
EOF
