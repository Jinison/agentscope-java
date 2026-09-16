# 腾讯云 AgentScope Service 部署记录

> 日期：2026-09-16
> 目标机器：`datadict-server`（81.70.51.239，Ubuntu 20.04，2C/2G）
> 部署方式：本地构建产物 → 上传 → 云端运行，数据库使用云端 PG（127.0.0.1:5432）

## 一、部署形态

| 平面 | 端口 | 可执行 |
| --- | --- | --- |
| aistiod（Go 控制面） | 8081 | `aistio/bin/aistiod`（本地交叉编译 linux/amd64，110M） |
| Dataplane | 8082 | `service-dataplane/target/service-dataplane-2.0.3-SNAPSHOT.jar`（135M） |
| Scheduler | 8083 | `service-scheduler/target/service-scheduler-2.0.3-SNAPSHOT.jar`（110M） |
| Gateway | 18080 | `service-gateway/target/service-gateway-2.0.3-SNAPSHOT.jar`（48M） |
| Console（SPA） | 由 Gateway 提供 | `aistio/ui/`（本地前端构建产物，1.7M） |

安装目录：`/home/ubuntu/apps/agentscope-java-src/agentscope-service/`
启动脚本：`scripts/deploy-asm.sh`（start/stop/status/restart，systemd 已接管）

## 二、构建方式（本地 Mac，Intel x86_64）

```bash
# 三个 Spring Boot fat jar（monorepo 根执行，约 15 分钟）
mvn -DskipTests -pl agentscope-service/service-gateway,agentscope-service/service-dataplane,agentscope-service/service-scheduler -am package

# aistiod 交叉编译（go.mod 要求 go 1.26；国内需 GOPROXY）
cd agentscope-service/aistio
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 GOPROXY=https://goproxy.cn,direct \
  go build -o /tmp/aistiod-linux-amd64 ./cmd/aistiod

# 前端 SPA（产物已存在，无需重构建）
agentscope-service/aistio/ui/   # vite build 输出
```

上传走 scp；大文件建议压缩后传（aistiod 可压到 46M，jar 几乎不可压）。

## 三、数据库

- 使用云端 PG（见 `腾讯云PostgreSQL部署记录-2026-09-15.md`），服务直连 `127.0.0.1:5432`。
- 角色/库：`builder` / `builder`，schema `cp`（产品数据）、`rt`（运行时）、`dp`（数据面）。
- 密码：云机 `/home/ubuntu/pg-builder-password.txt`；本机 `~/.agentscope-cloud-pg`（不入库）。
- `max_connections` 调至 100（默认 50 会被三个 JVM 连接池占满）。

## 四、启动 / 停止 / 状态

```bash
sudo systemctl start|stop|status agentscope-service   # systemd（开机自启）
# 或直接用脚本
bash ~/apps/agentscope-java-src/agentscope-service/scripts/deploy-asm.sh start|stop|status|restart
```

日志：`~/apps/agentscope-java-src/agentscope-service/.dev-stack/logs/{control,data,scheduler,gateway}.log`

## 五、访问

- 控制台：http://81.70.51.239:18080/ ，默认 `admin` / `admin`
- 登录接口：POST `/api/auth/login`（返回 JWT），受保护接口带 `Authorization: Bearer <token>`

## 六、本次踩坑记录

1. **本地上行限速**：部署当天本地上行仅 ~100KB/s（正常时 3.6MB/s），后台 nohup scp 会随 exec 会话退出而中断，
   最终改为前台阻塞式串行 scp + md5 校验，aistiod 用 gzip 预压缩省一半时间。
2. **rt schema 迁移冲突**：云端 PG 从本地 dump 恢复，`rt.schema_migrations` 是旧格式
   （`version text`，记录到 0010）；合并 main 后新 aistiod 用 golang-migrate（`version bigint, dirty bool`），
   启动时重跑 0013 迁移撞上已存在的 `teams` 表。解决：确认 rt 无业务数据后
   `DROP SCHEMA rt CASCADE; CREATE SCHEMA rt AUTHORIZATION builder;`，让 aistiod 全量迁移（0111 个迁移，66 张表）。
3. **UI assets 不完整**：第一次只传了 41/118 个 assets 文件，补齐整个 `aistio/ui/` 后 118/118。
