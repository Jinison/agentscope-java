# 修改记录：协作工具名修复 + task_get 访问器重构收尾

日期：2026-09-14 ~ 2026-09-15
项目：agentscope-java-main（asm-main 本地开发栈，无 git 仓库，故以本文记录全部改动）

## 一、背景与结论摘要

现象：AgentTask（评论触发的协作任务）对话在 DeepSeek 上全部失败，控制台报
`Invalid 'tools[i].function.name': string does not match pattern. Expected ... '^[a-zA-Z0-9_-]+$'`（HTTP 400）。

根因：注册给模型的工具函数名里含有点号 `.`。点号不在 OpenAI/DeepSeek 函数名允许字符集内，
请求直接被服务端拒绝，整个 turn 在模型请求阶段就失败。

结论：唯一可行的修复是让工具名符合 `^[a-zA-Z0-9_-]+$` 规范（改名），而不是绕过校验。

## 二、为什么不能“关掉对 . 的校验”

- 该校验在模型服务端（api.deepseek.com / OpenAI 兼容网关）执行，客户端没有任何开关。
- 客户端只能决定“发什么名字”，决定不了“服务端收什么名字”。
- 因此要么改名，要么换一家不校验函数名的模型/网关；对本项目来说改名为唯一正解。

## 三、修改一：工具名 task.submit_result -> task_submit_result（修复 400）

目的：让 AgentTaskOutcomeTool 的工具函数名通过 DeepSeek 服务端校验。

改动文件（共 2 个，6 处字符串）：
1. agentscope-extensions/agentscope-extensions-aistio/src/main/java/io/agentscope/extensions/aistio/adapter/AgentTaskOutcomeTool.java
   - @Tool(name = "task.submit_result") -> "task_submit_result"（1 处）
2. agentscope-extensions/agentscope-extensions-aistio/src/main/java/io/agentscope/extensions/aistio/adapter/HarnessAgentTaskStarter.java
   - 4 处提示文案 + 1 处 getToolNames().contains(...) 校验，同步改为 task_submit_result（5 处）

说明：改名必须连同提示文案和工具存在性检查一起改，否则模型会被提示去调用一个不存在的名字。

## 四、修改二：task_get 访问器重构收尾（让源码树恢复可编译）

背景：重构开始于 2026-09-14 20:54，把任务对象访问方式从 `task.getX()` 迁移为
`task.task_getX()`（访问器命名带 task_ 前缀，避免与其他 Task 概念混淆）。当时的源码只改了
调用点（且误把接收者 `task.` 一起吞掉，变成无接收者的 `task_getX()`），定义类没有同步，
导致源码树编译不过；运行中的 jar 全部是旧产物。

本次收尾方案：访问器保持实例方法，调用点补回接收者。语义与改动前完全等价。

改动文件（共 9 个）：
1. agentscope-core/src/main/java/io/agentscope/core/state/Task.java
   - 新增 9 个委托访问器：task_getId/task_getSubject/task_getDescription/task_getMetadata/
     task_getCreatedAt/task_getState/task_getOwner/task_getBlocks/task_getBlockedBy（保留原 getter）
2. agentscope-harness/src/main/java/io/agentscope/harness/agent/subagent/task/BackgroundTask.java
   - 新增 8 个委托访问器：task_getTaskId/task_getAgentId/task_getCreatedAt/task_getLastCheckedAt/
     task_getTaskStatus/task_getStatus/task_getResult/task_getError（保留原 getter）
3. 调用点补接收者（task_getX() -> task.task_getX()），共 53 处：
   - TaskTool.java（14）、WaitAsyncResultsTool.java（11）、SubagentsMiddleware.java（6）、
     WorkspaceTaskRepository.java（2）、AgentScopeAdapter.java（17）、
     HarnessAgentTaskStarter.java（2，该文件同时含修改一的改名）、ControlPlaneTaskRepository.java（1）
4. 两个模块运行 mvn spotless:apply 保持格式合规。

## 五、验证记录

- 2026-09-14 22:08：修复后的会话 sess_69b7b29c971e（issue 6b8c974c，修复验证团队 leader）
  端到端通过：模型请求成功（无 400）-> task_get/team_get -> run_node_complete -> agent.message
  -> session.status_idle；任务 completed，issue 进入 in_review。
- 2026-09-15 09:02 / 09:10：9887c58a 两个会话模型请求全部成功（48 个工具被 DeepSeek 接受），
  无 400；出现的错误为协议层 managed_turn_incomplete（见下）。
- 2026-09-15 09:26：清空全部 target 旧 jar 后重建（core + harness + extension-aistio +
  service-dataplane），build exit=0；新 jar 内工具名确认 task_submit_result。

## 六、已知未处理项

### managed_turn_incomplete（协议层，非工具名问题）
- 判定位置：agentscope-service/aistio/internal/httpapi/managed_session_event.go
  （session.status_idle 时若 AgentTask 未显式 task_complete/task_fail 则报 incomplete 并按模式处理）。
- 触发链：leader 委派后协议要求立即 task_complete(outcome=waiting)；DeepSeek 未照做，做大量独立
  验证，两次 task_complete 被控制面拒绝（waiting 需要 outstanding delegated work），随后迭代预算
  耗尽，文本收尾 -> incomplete。
- 建议方向（未实施）：委派轮提示更硬（禁止长验证、委派后必须立即 waiting）；leader 提高
  maxIters；或控制面在文本收尾时给出更明确的引导。是否修改由项目方决定。

### 审计专员（agent 36062cfc）v1 快照 model 为空
- 2026-09-14 20:35 创建时 model 为空串，20:43:58 已补 deepseek:deepseek-chat（v2/v3）。
- 20:43:26 的旧会话绑定 v1 空模型快照，触发 Model.getModelName() NPE；现 head 为 v3，新会话不受影响。

## 七、本次改动文件清单（源码，10 个）

1. agentscope-extensions/agentscope-extensions-aistio/src/main/java/io/agentscope/extensions/aistio/adapter/AgentTaskOutcomeTool.java（修改一）
2. agentscope-extensions/agentscope-extensions-aistio/src/main/java/io/agentscope/extensions/aistio/adapter/HarnessAgentTaskStarter.java（修改一 + 修改二）
3. agentscope-core/src/main/java/io/agentscope/core/state/Task.java（修改二）
4. agentscope-harness/src/main/java/io/agentscope/harness/agent/subagent/task/BackgroundTask.java（修改二）
5. agentscope-harness/src/main/java/io/agentscope/harness/agent/tool/TaskTool.java（修改二）
6. agentscope-harness/src/main/java/io/agentscope/harness/agent/tool/WaitAsyncResultsTool.java（修改二）
7. agentscope-harness/src/main/java/io/agentscope/harness/agent/middleware/SubagentsMiddleware.java（修改二）
8. agentscope-harness/src/main/java/io/agentscope/harness/agent/subagent/task/WorkspaceTaskRepository.java（修改二）
9. agentscope-extensions/agentscope-extensions-aistio/src/main/java/io/agentscope/extensions/aistio/adapter/AgentScopeAdapter.java（修改二）
10. agentscope-extensions/agentscope-extensions-aistio/src/main/java/io/agentscope/extensions/aistio/store/ControlPlaneTaskRepository.java（修改二）
