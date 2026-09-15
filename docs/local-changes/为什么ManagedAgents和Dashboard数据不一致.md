# 为什么 Managed Agents 和 Dashboard 数据对不上

> 结论：这是**设计上的两个独立数据域**，不是数据丢失或同步 bug。
> 验证时间：2026-09-14，本地无 Docker 栈（官方 v2.0.3 源码）

## 一、两个页面读的是两套数据

| 页面（顶部导航） | 路由 | 数据来源 | 内容定位 |
| --- | --- | --- | --- |
| **Managed Agents** | `/agents`、`/sessions`、`/workspaces`… | PostgreSQL `cp` schema（产品库） | 你在控制面创建/管理的 Agent、会话、工作区 |
| **Dashboard** | `/operate`、`/operate/agents`、`/operate/sessions` | PostgreSQL `rt` schema（运行时库）+ aistiod 内存注册表 | 自愿注册到控制面的**运行实例舰队**（BYO / External / Hosted） |

实测数据（本地库）：

```text
cp.agents    = 1     ← Managed Agents 页显示 1 个 Agent
cp.sessions  = 3     ← Managed Agents → Sessions 显示 3 条
rt.sessions  = 0     ← Dashboard 显示 0 条
rt.data_planes = 0   ← Dashboard 实例数 0
```

## 二、Dashboard 为什么是空的

Dashboard 的统计口径来自 `aistio/internal/httpapi/overview_handler.go`：

- `agentCount` / `instanceCount` / `dataplaneCount` ← `s.registry`（**内存注册表**，不是数据库表）
- `sessionCount` ← `rt.sessions`

而 `rt.sessions` 由 `aistio/internal/dataplane/poller.go` 填充：控制面**轮询已注册运行实例**的
`GET <baseUrl>/agentscope/sessions`，再 upsert 进运行时库。轮询条件是
`e.Healthy && e.ContractLevel >= 2 && e.BaseURL != ""`。

关键点：Java Dataplane 的**自我注册默认是关闭的**。源码注释写得很明确
（`service-dataplane/.../control/DataPlaneSelfRegistration.java`）：

> Disabled by default: the dataplane hosts Managed agent runs and should not appear as an
> Operate agent. Enable with `builder.dataplane.register-enabled=true` /
> `BUILDER_DATAPLANE_REGISTER=true` when that Operate visibility is intentionally desired.

所以默认配置下：没有任何实例注册 → 注册表为空 → Dashboard 全 0。
而 Managed Agent 是控制面直接托管的，走产品库，**本来就不进舰队视图**。

## 三、实测：打开注册开关会发生什么

把 `BUILDER_DATAPLANE_REGISTER=true` 打开后重启，Dashboard 确实有数字了：

```text
agentCount: 1,  instanceCount: 1,  healthyInstanceCount: 1,  dataplaneCount: 1,  sessionCount: 0
```

但 `/api/v1/agents` 里出现的“agent”是：

```json
{ "name": "agentscope-java-dataplane", "type": "BYO", "replicas": "1/1",
  "activeSessions": 0, "presence": "live" }
```

也就是说，出现的是**数据面自己**（名字是主机名，如 `sun7788deMacBook-Pro.local-f462738a`），
不是你的 Managed Agent `ag_dcec5224de07`。这正是源码注释警告的“基础设施不该冒充 Operate agent”。
`sessionCount` 依然是 0，因为 Dataplane 的 `/agentscope/sessions` 返回 `{"sessions":[]}`
（Managed 会话在产品库 `cp.sessions`，不通过该合约暴露）。

因此该开关已**还原为默认关闭**，但保留可覆盖：
`dev-up-local.sh` 里写成 `BUILDER_DATAPLANE_REGISTER="${BUILDER_DATAPLANE_REGISTER:-false}"`。

## 四、想看到什么，该去哪个页面

| 你想看 | 去哪 |
| --- | --- |
| 自己创建的 Managed Agent、会话、工作区 | **Managed Agents** 分区（`/agents`、`/sessions`） |
| Managed 会话的事件流、上下文、失败原因 | Managed Agents → Sessions → 打开具体会话（读 `dp.builder_session_event`） |
| BYO / External / Hosted 运行实例的舰队视图 | **Dashboard** 分区（`/operate`）——需要先有实例注册进来 |

## 五、想让 Dashboard 真正有数据，正确的做法

Dashboard 是「舰队」视图，需要**真实的运行实例注册进来**，而不是打开 Dataplane 自注册：

1. **BYO 示例**：跑仓库自带的 `agentscope-examples/agents/agentscope-paw`，它会把自己注册进控制面，
   Dashboard 就会出现它（这也是 `agentscope-service/README_zh.md` 里推荐体验的路径）。
2. **Hosted Agent**：用 `agentscope connect` 连接本机的 Coding Agent（Codex / Claude Code 等），
   Runtime Host 注册后会在 Dashboard 出现，并能观察到 Session。
3. **External Agent**：用 `agentscope-extensions-aistio` 的 `Aistio.instrument(...)` 把自有应用注册进来。

## 六、一句话总结

`cp`（产品库）和 `rt`（运行时库）是两套数据；Managed Agents 读前者，Dashboard 读后者。
Managed Agent 不注册进舰队视图是**预期行为**，要看它们的运行情况请用
Managed Agents → Sessions，而不是 Dashboard。
