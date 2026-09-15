# 腾讯云 PostgreSQL 部署记录

> 日期：2026-09-15
> 目标：把本地 AgentScope Service 开发栈用的 PostgreSQL 17 数据库（库 `builder`，schema `cp`/`rt`/`dp`）
> 部署到腾讯云机器 `datadict-server`，云端可直接使用同一份数据。

## 一、机器与版本

| 项 | 值 |
| --- | --- |
| SSH 别名 | `datadict-server`（81.70.51.239:22，用户 `ubuntu`） |
| 系统 | Ubuntu 20.04.6 LTS，2 vCPU / 1.9 GiB 内存 / 40G 盘 |
| 安装方式 | apt + PGDG 源（走阿里云镜像 `mirrors.aliyun.com/postgresql/repos/apt/` focal-pgdg） |
| 版本 | PostgreSQL 17.4（本地为 Postgres.app 17.11，同一大版本，dump/restore 兼容） |
| 集群 | `17/main`，端口 5432，数据目录 `/var/lib/postgresql/17/main` |
| 监听 | `listen_addresses = localhost`，只对本机开放，未暴露公网 |
| 自启 | `systemctl is-enabled postgresql` = enabled，开机自动启动 |

安装命令（概览）：

```bash
# PGDG 源（阿里云镜像，国内速度快）
echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] \
https://mirrors.aliyun.com/postgresql/repos/apt/ focal-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg
sudo apt-get update && sudo apt-get install -y postgresql-17 postgresql-client-17 postgresql-contrib-17
```

## 二、参数调整（2G 小机器，保守取值）

配置文件：`/etc/postgresql/17/main/conf.d/10-agentscope.conf`

| 参数 | 值 | 说明 |
| --- | --- | --- |
| `listen_addresses` | `localhost` | 只监听本机 |
| `shared_buffers` | 128MB | 默认值，2G 机器不宜再大 |
| `effective_cache_size` | 768MB | 优化器估算 |
| `work_mem` | 4MB | 并发不高，够用 |
| `maintenance_work_mem` | 64MB | 备份/维护 |
| `max_connections` | 50 | 降低空闲连接内存占用 |
| `wal_compression` | on | 省磁盘 |
| `timezone` | Asia/Shanghai | 与本地一致 |
| `log_min_duration_statement` | 500ms | 慢查询记录 |

注意：`shared_buffers`、`max_connections` 这类参数**必须 restart 才生效**，只 reload 会保持旧值
（本次就踩了一次：reload 后 `max_connections` 仍是 100，重启后才变成 50）。

```bash
sudo systemctl restart postgresql@17-main
```

## 三、角色与库（与本地保持一致）

| 项 | 值 |
| --- | --- |
| 角色 | `builder` / 密码 `builder`（LOGIN + CREATEDB） |
| 数据库 | `builder`，owner `builder`，UTF8 / `en_US.UTF-8` |
| schema | `cp`、`rt`、`dp`（由 dump 恢复） |
| 扩展 | `pgcrypto`、`plpgsql` |

## 四、数据迁移

```bash
# 本机导出
pg_dump -h 127.0.0.1 -p 5432 -U builder -d builder -Fc -f /tmp/builder-local-20260915.dump
scp /tmp/builder-local-20260915.dump datadict-server:/tmp/

# 云机恢复（--role=builder 让对象归属 builder，便于后续迁移改表）
sudo -u postgres pg_restore -d builder --no-owner --no-privileges \
  --role=builder -j 2 /tmp/builder-local-20260915.dump
```

迁移结果：`pg_restore` 退出码 0、0 条 error；`cp`/`rt`/`dp` 共 61 张表，逐表行数与本地**完全一致**；
库大小 11 MB。

## 五、怎么连

云端没有开放公网 5432，也没有改腾讯云安全组。从本机访问走 SSH 隧道：

```bash
ssh -N -L 15432:127.0.0.1:5432 datadict-server     # 保持前台不退出
psql "postgresql://builder:builder@127.0.0.1:15432/builder?sslmode=disable"
```

对应到 AgentScope Service 的配置：

```text
JDBC: jdbc:postgresql://127.0.0.1:15432/builder?currentSchema=dp
DSN : postgres://builder:builder@127.0.0.1:15432/builder?sslmode=disable&search_path=rt
```

云机上直连（不经隧道）：

```bash
psql "postgresql://builder:builder@127.0.0.1:5432/builder?sslmode=disable"
```

## 六、常用运维

```bash
sudo systemctl status  postgresql@17-main     # 状态
sudo systemctl restart postgresql@17-main     # 重启
sudo tail -f /var/log/postgresql/postgresql-17-main.log

# 云端备份
sudo -u postgres pg_dump -Fc builder -f /home/ubuntu/builder-$(date +%F).dump
```

## 七、注意事项

- 5432 未对公网开放。若确实要直连，需要腾讯云安全组放行来源 IP，并在 `pg_hba.conf` 里限定来源，
  同时把 `builder` 的弱密码换掉。
- 云端这份是 2026-09-15 当日本地数据的副本；本地开发栈仍连本地 5432，两边目前不会自动同步。
- 云端机器上还跑着 MySQL/Redis/nginx 等其它服务，PG 已按小内存配置收敛，避免与它们抢资源。
