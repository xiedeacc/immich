# Immich 部署信息

当前主机上的 Immich 是 **裸机/systemd 部署**，不是 Docker Compose 部署。

当前仓库分支：`deploy`。

## 部署目录

- 应用根目录：`/opt/immich`
- 服务端代码：`/opt/immich/server`
- Nginx 静态前端目录：`/opt/immich/web/build`
- Immich v3 SSR 兼容路径：`/opt/immich/www -> /opt/immich/web/build`
- 机器学习服务目录：`/opt/immich/machine-learning`
- 上传和媒体数据目录：`/opt/immich/upload`
- 运行用户/用户组：`tiger:tiger`
- root/tiger 共享 nvm 目录：`/opt/software/src/tools/nvm`
- 当前 Immich 版本：`3.0.1`
- 当前线上版本：`3.0.1`
- 本次升级前版本：`2.5.6`
- 目标升级版本：`3.0.1`
- 升级完成时间：`2026-07-04`

## Systemd 服务

### Immich Server

- 服务文件：`/etc/systemd/system/immich.service`
- 工作目录：`/opt/immich/server`
- 环境变量文件：`/etc/immich/immich.env`
- 启动命令：

```bash
/opt/software/src/tools/nvm/versions/node/v24.18.0/bin/node /opt/immich/server/dist/main.js
```

### Immich Machine Learning

- 服务文件：`/etc/systemd/system/immich-ml.service`
- 工作目录：`/opt/immich/machine-learning`
- 环境变量文件：`/opt/immich/conf/immich-ml.env`
- 启动命令：

```bash
/opt/immich/machine-learning/.venv/bin/python -m immich_ml
```

## 环境配置

### 主服务配置

配置文件：`/etc/immich/immich.env`

关键配置：

- PostgreSQL 主机：`/var/run/postgresql`
- PostgreSQL 用户：`immich`
- PostgreSQL 数据库：`immich`
- PostgreSQL peer 映射：系统用户 `tiger` 映射到数据库用户 `immich`
- Redis 主机：`127.0.0.1`
- Redis 端口：`6379`
- Immich 监听地址：`0.0.0.0`
- Immich 监听端口：`2283`
- 机器学习服务地址：`http://127.0.0.1:3003`
- 上传目录：`/opt/immich/upload`
- 媒体目录：`/opt/immich/upload`
- 外部访问域名：`https://immich.xiedeacc.com`

### 机器学习服务配置

配置文件：`/opt/immich/conf/immich-ml.env`

该文件原先位于 `/etc/immich/immich-ml.env`，现在已迁移到 `/opt/immich/conf/immich-ml.env`。

`/etc/systemd/system/immich-ml.service` 中的 `EnvironmentFile` 已更新为：

```ini
EnvironmentFile=/opt/immich/conf/immich-ml.env
```

关键配置：

- ML 监听地址：`0.0.0.0`
- ML 监听端口：`3003`
- ML 缓存目录：`/opt/immich/machine-learning/.cache`
- Transformers 缓存目录：`/opt/immich/machine-learning/.cache`

## Nginx 配置

- 主配置文件：`/etc/nginx/nginx.conf`
- TLS 证书目录：`/etc/nginx/ssl/`
- 访问域名：`immich.xiedeacc.com`
- HTTPS 监听端口：`443`
- API 反向代理：

```nginx
location /api {
    proxy_pass http://127.0.0.1:2283;
}
```

- 静态前端目录：

```nginx
location / {
    root /opt/immich/web/build;
    try_files $uri $uri/ /index.html;
}
```

## 本地服务和端口

- Immich API：`127.0.0.1:2283`
- Immich 机器学习服务：`0.0.0.0:3003`
- PostgreSQL 16：`127.0.0.1:5432`
- Redis：`127.0.0.1:6379`
- Nginx：`80`、`443`、`444`

## 数据和存储

`/opt/immich` 总大小约为 `332G`。

为减少 `/dev/mmcblk0p2` 根分区的占用和写入，以下目录已迁移到 `/opt` 并通过 bind mount 保持原路径兼容：

- `/var/lib/postgresql -> /opt/var/lib/postgresql`
- `/var/lib/mysql -> /opt/var/lib/mysql`
- `/var/log -> /opt/var/log`
- `/var/opt -> /opt/var/opt`
- `/var/cache -> /opt/var/cache`
- `/var/lib/apt -> /opt/var/lib/apt`
- `/usr/local -> /opt/usr/local`

`/etc/fstab` 已写入对应 bind mount。`/tmp` 已配置为下次启动使用 `tmpfs`，大小上限 `2G`。

日志限制：

- systemd journal：`SystemMaxUse=100M`、`RuntimeMaxUse=100M`
- GitLab logrotate：`logrotate_size=100M`、`logrotate_rotate=1`

上传目录配置位置：

- 配置文件：`/etc/immich/immich.env`
- 关键配置：

```env
UPLOAD_LOCATION=/opt/immich/upload
IMMICH_MEDIA_LOCATION=/opt/immich/upload
```

`immich.service` 通过以下配置加载该文件：

```ini
EnvironmentFile=/etc/immich/immich.env
```

目录占用：

- `/opt/immich/upload`：约 `331G`
- `/opt/immich/upload/library`：约 `258G`
- `/opt/immich/upload/encoded-video`：约 `35G`
- `/opt/immich/upload/upload`：约 `24G`
- `/opt/immich/upload/thumbs`：约 `14G`
- `/opt/immich/upload/backups`：约 `967M`

## 数据库

- PostgreSQL 集群：`16/main`
- 数据库名：`immich`
- 观测到的数据库大小：约 `372 MB`

## Geodata

Immich 已配置真实 geodata 数据，不是空数据或测试数据。

- geodata 文件目录：`/opt/immich/geodata`
- geodata 构建数据根目录：`IMMICH_BUILD_DATA=/opt/immich`
- 文件来源类型：GeoNames `cities500/admin1/admin2` + Natural Earth 国家边界数据
- 数据日期：`2026-02-18`
- 数据库导入状态：
  - `geodata_places`：`223162` 条
  - `naturalearth_countries`：`4274` 条
- 反向地理编码：已开启
- 状态记录：

```text
reverse-geocoding={"enabled": true}
reverse-geocoding-state={"lastUpdate": "2026-02-18\n", "lastImportFileName": "cities500.txt"}
```

运行时配置来源：

```env
IMMICH_BUILD_DATA=/opt/immich
```

Immich 会从 `/opt/immich/geodata` 读取：

```text
admin1CodesASCII.txt
admin2Codes.txt
cities500.txt
geodata-date.txt
ne_10m_admin_0_countries.geojson
```

## 备份

数据库备份目录：

```text
/opt/immich/upload/backups
```

最新观测到的备份文件：

```text
/opt/immich/upload/backups/immich-db-backup-20260704T020000-v2.5.6-pg16.14.sql.gz
```

## 健康检查

服务端 ping：

```bash
curl http://127.0.0.1:2283/api/server/ping
```

预期响应：

```json
{"res":"pong"}
```

服务端版本：

```bash
curl http://127.0.0.1:2283/api/server/version
```

观测到的响应：

```json
{"major":3,"minor":0,"patch":1,"prerelease":null}
```

机器学习服务 ping：

```bash
curl http://127.0.0.1:3003/ping
```

预期响应：

```text
pong
```

## HEIC 缩略图支持

Immich 使用 sharp/libvips 生成图片缩略图。sharp 默认预编译 libvips 在当前环境下只识别 `.avif`，不能正确解码 iPhone 常见的 `.heic/.heif`，会导致日志出现：

```text
heif: Error while loading plugin: Support for this compression format has not been built in
AssetGenerateThumbnails
```

当前已将线上 sharp 原生模块重编译为链接系统 libvips：

```text
/opt/immich/server/node_modules/sharp/src/build/Release/sharp-linux-x64.node
```

验证结果：

```text
sharp=0.34.5
vips=8.17.3
heif suffixes=.heic,.heif,.avif
```

`scripts/deploy.sh` 已加入 `rebuild_sharp_with_system_libvips`，后续部署会自动重编译 sharp 并校验 HEIC 支持，避免被预编译包覆盖。

## 常用命令

查看服务状态：

```bash
systemctl status immich immich-ml nginx postgresql@16-main redis-server
```

查看服务端日志：

```bash
journalctl -u immich.service -f
```

查看机器学习服务日志：

```bash
journalctl -u immich-ml.service -f
```

查看服务是否开机自启：

```bash
systemctl is-enabled immich.service immich-ml.service postgresql@16-main.service redis-server.service nginx.service
```

## 裸机升级脚本

升级脚本：

```text
/opt/software/src/immich/scripts/deploy.sh
```

脚本目标：

- 从当前仓库拉取 `v3.0.1` tag
- 在 `/opt/software/src/immich/immich-build` 下创建临时 worktree 和 staging 目录
- 缺失工具安装到 `/opt/software/src/tools`
- 构建 server、web、CLI、core plugin 和 machine-learning
- 停止 `immich.service` 和 `immich-ml.service`
- 只同步代码和构建产物到 `/opt/immich`
- 修正代码目录权限，保证 `nginx` 可读取 `/opt/immich/web/build`
- 创建 `/opt/immich/www` 指向 `/opt/immich/web/build`，满足 Immich v3 的 SSR 静态文件路径
- 启动 `immich-ml.service` 和 `immich.service`
- 执行本地健康检查

执行前置条件和工具安装：

- 需要 root 权限
- 需要本机已安装 `git`、`rsync`、`curl`
- 需要 `/opt/software/src/tools/nvm/versions/node/v24.18.0/bin/node`
- 需要 `/opt/software/src/tools/nvm/versions/node/v24.18.0/bin/pnpm`
- 如果缺少 `mise`，脚本会自动安装 `mise 2026.6.10` 到 `/opt/software/src/tools/bin/mise`
- 如果缺少 `uv` 或版本不匹配，脚本会自动安装 `uv 0.8.15` 到 `/opt/software/src/tools/bin/uv`
- `mise` 用于构建 v3 的 core plugin
- `uv` 的 Python 安装目录固定为 `/opt/software/src/tools/uv-python`，并使用 copy 模式，避免虚拟环境指向 root 私有目录

明确保护：

- 不删除 `/opt/immich/upload`
- 不移动 `/opt/immich/upload`
- 不同步覆盖 `/opt/immich/upload`
- 不备份 `/opt/immich/upload`

脚本会备份当前代码目录到 `/opt/immich/code-backups/...`，但显式排除 `/opt/immich/upload`。

本次升级过程中已处理的问题：

- `pnpm deploy --no-optional` 会漏掉 `sharp` 的 Linux 平台运行时包，脚本已改为 server 部署保留 optional dependencies。
- 数据库角色 `immich` 原有 `statement_timeout=1min` 会打断 v3 迁移，已调整为 `statement_timeout=0` 和 `idle_in_transaction_session_timeout=0`。
- 前端产物初始权限为 `600/700` 会导致 Nginx 返回 `403`，已修正为目录 `755`、文件 `644`。
- `immich.service`、`immich-ml.service`、`tbox_client.service` 已切换为 `tiger:tiger` 运行。
- PostgreSQL `/etc/postgresql/16/main/pg_ident.conf` 增加 `tiger -> immich` 映射，以保持 Immich 继续使用数据库用户 `immich`。

执行方式：

```bash
/opt/software/src/immich/scripts/deploy.sh
```
