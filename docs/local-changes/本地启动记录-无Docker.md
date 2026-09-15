# AgentScope Service v2.0.3 本地启动记录（无 Docker 环境）

> 日期：2026-09-14
> 源码：`/Users/sun7788/Downloads/agentscope-java-2.0.3/`（用户下载的源码包）
> Console：http://localhost:8080/ ，账号 `admin` / `admin`

## 一、为什么不是官方那条命令

官方 README 的本地启动是：

```bash
cd agentscope-service
scripts/dev-down.sh && BUILDER_REBUILD=1 scripts/dev-up.sh
```

前提是 **Docker**（脚本用它起 PostgreSQL 容器）。本机没有 Docker，且
`brew install colima` 在 Intel Mac 上要从源码编译 QEMU，实测十几分钟无进展，已放弃。

因此保留官方脚本的全部逻辑，只把「Postgres 段」从 `docker run postgres:17`
换成**本地 PostgreSQL 17.11**（Postgres.app 二进制），生成 `scripts/dev-up-local.sh`。
其余四个平面（aistiod / Dataplane / Scheduler / Gateway）与官方完全一致。

另外：官方 Release 页面写的 `agentscope-service-VERSION-compose.tar.gz` 目前**尚未发布**
（GitHub Releases v2.0.3 附件数为 0），所以现成 Compose 包这条路暂时走不通。

## 二、本机工具链（均已就位）

| 组件 | 版本 | 位置 |
| --- | --- | --- |
| JDK | 17.0.2 (Temurin) | 系统默认 |
| Maven | 3.9.12 | 系统默认（已配阿里云镜像 `~/.m2/settings.xml`） |
| Go | 1.26.8 | `~/toolchain/go1.26.8`（aistiod 要求 1.26+） |
| PostgreSQL | 17.11 | `~/toolchain/Postgres.app/Contents/Versions/17`，数据目录 `~/toolchain/pgdata` |

## 三、启动步骤（当前实际使用的）

```bash
cd /Users/sun7788/Downloads/agentscope-java-2.0.3
export PATH="$HOME/toolchain/go1.26.8/bin:$PATH"
export LANG=C.UTF-8 LC_ALL=C.UTF-8
./agentscope-service/scripts/dev-up-local.sh
```

脚本做的事：建/起本地 Postgres → 建 `cp/rt/dp` 三个 schema →
起 aistiod(:8081) → Dataplane(:8082) → Scheduler(:8083) → Gateway(:8080) → 逐个健康检查。

停止（含停本地 Postgres）：

```bash
BUILDER_STOP_PG=1 ./agentscope-service/scripts/dev-down.sh
```

日志目录：`agentscope-service/.dev-stack/logs/{control,data,scheduler,gateway,postgres}.log`

## 四、启动结果（实测）

```text
  OK control healthy on :8081
  OK data healthy on :8082
  OK scheduler healthy on :8083
  OK gateway healthy on :8080
Console (SPA via gateway): http://localhost:8080/
```

- `GET /actuator/health` → UP
- `GET /healthz`（aistiod）→ {"status":"ok"}
- 登录 `POST /api/auth/login`（admin/admin）→ 200，roles `[user, admin]`
- 管理 API `/api/agents`、`/api/environments`、`/api/sessions` → 200
- SPA 资源 `/assets/index-*.js` → 200（前端是包内预置的，无需 npm 构建）

## 五、DeepSeek 模型接入（关键，只差一个 key）

已完成的代码准备：给 `service-dataplane/pom.xml` 增加依赖
`agentscope-extensions-model-openai`，并重新构建 dataplane。
该扩展内含官方 **DeepSeek provider**：

- provider id 前缀：`deepseek:<model>`（例如 `deepseek:deepseek-chat`、`deepseek:deepseek-reasoner`）
- 自动读取环境变量：`DEEPSEEK_API_KEY`
- 默认 base URL：`https://api.deepseek.com`

**验证证据**：创建一个 `model = deepseek:deepseek-chat` 的 Agent 并跑一轮会话，事件流返回：

```text
user.message
session.status_running
session.error: Failed to create model for id: deepseek:deepseek-chat:
               Environment variable DEEPSEEK_API_KEY is required to auto-create model
session.status_terminated
```

说明 provider 已被正确加载，只缺 key。

### 你后面要做的事（已封装成两步）

已提供脚本 `scripts/start-with-deepseek.sh`，它会自动读取 key、停旧栈、带 key 重启。

```bash
# 第 1 步（只做一次）：写入 key，权限 600
echo 'export DEEPSEEK_API_KEY=sk-你的key' > ~/.deepseek-key
chmod 600 ~/.deepseek-key

# 第 2 步：启动
cd /Users/sun7788/Downloads/agentscope-java-2.0.3
./agentscope-service/scripts/start-with-deepseek.sh
```

2. 在 Console 里新建 Agent 时把 **模型填 `deepseek:deepseek-chat`**（已预置一个
   “DeepSeek 助手” Agent，id `ag_dcec5224de07`，可直接用）。

3. 打开 Sessions → 新建绑定该 Agent 与 `local` Environment 的 Session → 发消息。

## 六、已知限制

- 无 Docker：E2B sandbox、`self_hosted` Worker 这类依赖容器的能力不可用；`local` 环境可用。
- 模型默认是 DashScope（`DASHSCOPE_API_KEY`）；不填 key 时只有 DeepSeek 路径会报错，控制台功能不受影响。
- 该栈是**本地开发栈**（`AISTIO_ENABLE_KUBERNETES=false`），没有 CRD Reconciler 与 ASDP gRPC。

## 七、后续修正（2026-09-14 18:35 实测）

1. **`dev-up-local.sh` 自动读取 key**：启动时若环境里没有 `DEEPSEEK_API_KEY`，会 source
   `~/.deepseek-key`（可用 `BUILDER_CRED_FILE` 改路径）并 export 给四个进程，成功时打印
   `==> DeepSeek credential loaded (...)`，读不到时打印 WARN。这样直接跑
   `dev-up-local.sh` 和跑 `start-with-deepseek.sh` 效果一致——之前 18:13 那次栈是直接跑
   `dev-up-local.sh` 起的，data plane 进程环境里没有 key，所以会话报
   `Environment variable DEEPSEEK_API_KEY is required to auto-create model`。
2. **健康检查超时放宽**：`wait_health` 由 60/90/90/30 秒统一改为 240 秒。本机 JVM 冷启动实测
   数据面 100~130 秒、网关 71 秒，旧超时会误报 `FAIL data did not become healthy within 90s`。
3. **验证结果**：新建 session（agent `ag_dcec5224de07` + environment `local`）发一条消息，事件流为
   `user.message → session.status_running → span.model_request_start → span.model_request_end →
   agent.message("1+1等于2。") → session.status_idle`，无 `session.error`。
4. **未改动项（上游代码缺陷）**：`SessionEventLog.subscribe`（service-common）用
   `Flux.interval(...).concatMap(DB 轮询)`，下游补充请求慢于 tick 时会抛 Reactor
   `OverflowException`，表现为日志里的 `Unhandled API error`（18:17:17 那条）。客户端会自动重连，
   不影响功能。修法是给 interval 加背压丢弃，需重建 service-common + dataplane：

   ```java
   return Flux.interval(Duration.ofMillis(pollIntervalMs))
           .onBackpressureDrop()
           .concatMap(...);
   ```

5. **`postgres.log` 里的 `FATAL: role "sun7788" does not exist`**：来自脚本里的
   `pg_isready`（未带 `-U builder`）探活，属正常噪声，与应用连接无关。
