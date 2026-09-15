# AgentScope Service v2.0.3 · 本地运行（无 Docker）

官方 [quickstart](https://java.agentscope.io/v2/zh/service/quickstart) 的本地启动需要一个
`agentscope-service-VERSION-compose.tar.gz` + Docker。本机没有 Docker（且该 Compose 包官方尚未发布），
因此用**本地 PostgreSQL 17.11 顶替容器**，四个平面与官方完全一致。

## 一键使用（填 key 即可）

```bash
# 第 1 步：写入 DeepSeek key（只做一次）
echo 'export DEEPSEEK_API_KEY=sk-你的key' > ~/.deepseek-key
chmod 600 ~/.deepseek-key

# 第 2 步：启动
cd "/Users/sun7788/Documents/Codex/AgentScope学习笔记/04-官方Service-v2.0.3"
./scripts/start.sh
```

然后打开 http://localhost:8080 ，用 `admin` / `admin` 登录。

## 脚本说明

| 脚本 | 作用 |
| --- | --- |
| `scripts/start.sh` | 读取 DeepSeek key → 停旧栈 → 启动四平面（含本地 PostgreSQL） |
| `scripts/stop.sh` | 停止全部（含本地 PostgreSQL，数据保留） |
| `scripts/status.sh` | 查看端口健康、登录可用性、key 是否就位 |
| `scripts/service-env.sh` | 公共变量（`SERVICE_HOME`、Go 路径、locale、key 文件路径） |

Service 安装目录默认取 `~/Downloads/agentscope-java-2.0.3/agentscope-service`；
换位置时 `export SERVICE_HOME=/path/to/agentscope-service` 即可。

## 运行形态

| 组件 | 端口 | 说明 |
| --- | --- | --- |
| Gateway | 8080 | 公共入口 + Console（SPA） |
| aistiod | 8081 | Go 控制面：`/api/*`、`/api/v1/*`、Console 静态资源 |
| Dataplane | 8082 | Managed Session / HarnessAgent / 事件日志 |
| Scheduler | 8083 | 渠道、Cron、出站任务 |
| PostgreSQL | 5432 | schema `cp` / `rt` / `dp`，数据目录 `~/toolchain/pgdata` |

日志：`~/Downloads/agentscope-java-2.0.3/agentscope-service/.dev-stack/logs/`

## 模型配置

默认模型是 DashScope（环境变量 `DASHSCOPE_API_KEY`，默认 `qwen-max`）。
DeepSeek 走官方 `agentscope-extensions-model-openai` 里的 provider：

- 模型 id 写法：`deepseek:deepseek-chat`（或 `deepseek:deepseek-reasoner`）
- 读取环境变量：`DEEPSEEK_API_KEY`
- 默认 base URL：`https://api.deepseek.com`

已预置一个 Agent：**DeepSeek 助手**（`ag_dcec5224de07`，model=`deepseek:deepseek-chat`），
在 Console 的 Sessions 里建会话绑它 + `local` Environment 即可对话。

## 常见疑问

- **Managed Agents 和 Dashboard 数据对不上？** 正常。两者读不同数据库：Managed Agents 读产品库
  `cp.*`，Dashboard 读运行时库 `rt.*`（由注册进来的运行实例填充）。Managed Agent 不进舰队视图是
  预期行为。详见 [为什么ManagedAgents和Dashboard数据不一致.md](为什么ManagedAgents和Dashboard数据不一致.md)。

## 详细记录

完整搭建过程、验证证据与已知限制见 [本地启动记录-无Docker.md](本地启动记录-无Docker.md)。
