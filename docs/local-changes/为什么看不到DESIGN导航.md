# 为什么本地部署看不到文档里的 DESIGN 导航

> 结论：**文档描述的是未发布的新版控制台（main 分支），你部署的 v2.0.3 发布包是上一代布局。**
> 不是你部署错了，也不是配置问题。
> 验证时间：2026-09-14

## 一、直接证据

**1) 你本地实际加载的页面资源里没有 DESIGN**

```bash
JS=$(curl -s http://localhost:8080/ | grep -oE '/assets/index-[^"]+\.js')
curl -s "http://localhost:8080$JS" > /tmp/ui.js
grep -c "DESIGN" /tmp/ui.js      # → 0
```

bundle 里的真实导航结构：

```js
[
  { id: "dashboard", label: "Dashboard",      items: [Overview, Agents, Sessions, Governance] },
  { id: "managed",   label: "Managed Agents", items: [Agents, Sessions, Workspaces,
                                                       Environments, Memory, Vaults,
                                                       Deployments, Channels] },
  { id: "teams",     label: "Teams",          items: [Overview, Teams, Templates] }
]
```

**2) 线上 main 分支的导航才是文档写的那套**

`agentscope-service/frontend/src/app/AppShell.tsx`（main）：

```js
{ label: 'Work',      items: [Chat, Issues, Inbox, Automations] },
{ label: 'Design',    items: [Agents(/agent-center/agents), Teams, Workflows, Channels] },
{ label: 'Resources', items: [Workspaces, Environments, Memory, Vault] }
```

**3) 文档页自己也标了未发布**

线上 `/v2/zh/service/agents` 页面里「预览」「尚未发布」各出现 2 次。

**4) 新控制台依赖的接口，你的 v2.0.3 后端根本没有**

```text
GET /api/v1/work/overview          → 404
GET /api/v1/agent-center/agents    → 404
GET /api/v1/issues                 → 404
GET /api/v1/workflows              → 404
GET /api/v1/teams                  → 200
```

所以把新前端换上去也只会是坏的——后端没有 `agent-center` / `work` / `workflows` / `issues` 这些能力。

## 二、功能对照：文档位置 → 你 v2.0.3 里的位置

| 文档（新版控制台） | 你的 v2.0.3 控制台 |
| --- | --- |
| Design → Agents | **Managed Agents → Agents**（`/agents`） |
| Design → Teams | 顶部 **Teams**（`/teams`） |
| Design → Channels | **Managed Agents → Channels**（`/channels`） |
| Design → Workflows | **不存在**（v2.0.3 无工作流能力） |
| Resources → Workspaces | **Managed Agents → Workspaces**（`/workspaces`） |
| Resources → Environments | **Managed Agents → Environments**（`/environments`） |
| Resources → Memory | **Managed Agents → Memory**（`/memory-stores`） |
| Resources → Vault | **Managed Agents → Vaults**（`/vaults`） |
| Work → Chat | 会话入口：**Managed Agents → Sessions**（`/sessions`，Agent 详情里的 chat 会重定向到此） |
| Work → Issues | **不存在** |
| Work → Inbox | **不存在** |
| Work → Automations | **不存在** |
| （无对应） | **Dashboard**（`/operate`）只有 v2.0.3 有，新版挪进 Operate 流程 |

v2.0.3 前端的完整路由（来自 `frontend/src/main.tsx`）：

```
/login  /agents  /agents/new  /sessions  /sessions/new  /sessions/:sessionId
/workspaces  /workspaces/:id  /profile  /admin/users  /environments
/memory-stores  /vaults  /deployments  /channels  /channels/:channelId
/agents/:id/{workspace,channels,skills,tools,...}  /teams*  /operate*
```

## 三、想用新控制台怎么办

| 选项 | 说明 |
| --- | --- |
| A. 继续用 v2.0.3（推荐） | 功能都在，只是分组名不同，按上面表格找即可 |
| B. 整套升级到 main 分支 | 前后端都要换（新 UI 依赖新 API），相当于重新部署一套；main 的控制面还涉及 CRD/K8s 能力 |
| C. 等官方发布下一版 | 文档页标注「预览」，正式版尚未发布 |

**只换前端不行**——第 4 条证据已经说明后端缺接口。
