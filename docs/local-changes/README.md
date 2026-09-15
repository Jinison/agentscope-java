# 本地修改与问题排查记录

> 本目录集中存放 agentscope-java-main 本地开发过程中产生的修改记录与问题排查文档。

## 文档索引

| 文档 | 内容 |
| --- | --- |
| [修改记录-工具名修复与task_get重构.md](./修改记录-工具名修复与task_get重构.md) | 修复工具名 `task.submit_result` 的 400 错误，并完成 `task_get*` 访问器重构收尾 |
| [已修复的问题.md](./已修复的问题.md) | main 分支新版控制台遇到的问题及修复过程 |
| [本地启动记录-无Docker.md](./本地启动记录-无Docker.md) | 无 Docker 环境下本地启动 AgentScope Service 的记录 |
| [模型配置说明.md](./模型配置说明.md) | AgentScope Service 中模型配置的分层说明 |
| [为什么ManagedAgents和Dashboard数据不一致.md](./为什么ManagedAgents和Dashboard数据不一致.md) | Managed Agents 与 Dashboard 数据口径不同的原因 |
| [为什么看不到DESIGN导航.md](./为什么看不到DESIGN导航.md) | 文档里的 DESIGN 导航与本地/发布版控制台布局差异说明 |
| [README-本地版.md](./README-本地版.md) | 本地运行 AgentScope Service（无 Docker）的快速说明 |
| [腾讯云PostgreSQL部署记录-2026-09-15.md](./腾讯云PostgreSQL部署记录-2026-09-15.md) | 把本地 PG 库部署到腾讯云 `datadict-server` 的过程、参数与连接方式 |

## 使用建议

- 这些文档记录的是本机开发环境与修复过程，路径中若出现绝对路径，请按实际环境替换。
- 代码层面的修复已落在对应源码中，本文档用于追溯原因与排查步骤。
