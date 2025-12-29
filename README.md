# Docker Git Wrapper (Auto-Sync Sidecar)

这是一个工具集，可以将任意 Docker 镜像（Nginx, Node, MySQL 等）自动封装成带有 **Git 双向同步功能** 的镜像。
特别适用于 PAAS 平台（如 Render, Railway, Zeabur）等不支持持久化 Volume 的场景。

## 🚀 如何生成镜像

1. 进入 GitHub 仓库的 **Actions** 页面。
2. 选择 **"Wrap Image (Git Sync)"**。
3. 输入参数：
   - **Base Image**: 你想封装的原镜像 (如 `nginx:alpine`)
   - **Target Tag**: 新镜像的名字 (如 `my-nginx-backup`)
4. 等待运行完成，获取镜像地址：
   `ghcr.io/<你的用户名>/<Target Tag>:latest`

## 🐳 运行时环境变量 (ENV)

部署该镜像时，**必须**配置以下环境变量。为避免冲突，所有变量均以 `GW_` 开头。

| 变量名 | 必填 | 示例 / 说明 |
| :--- | :--- | :--- |
| **GW_REPO_URL** | ✅ | `https://github.com/username/my-data.git` (私有仓库HTTPS地址) |
| **GW_USER** | ✅ | `username` (GitHub 用户名) |
| **GW_PAT** | ✅ | `ghp_xxxxxx` (GitHub Personal Access Token) |
| **GW_SYNC_MAP** | ✅ | `data/conf:/etc/nginx;data/html:/usr/share/nginx/html`<br>格式：`<Git内路径>:<容器内路径>`，多个路径用分号 `;` 隔开 |
| `GW_BRANCH` | ❌ | `main` (默认分支) |
| `GW_INTERVAL` | ❌ | `300` (同步间隔，单位秒，默认 5 分钟) |
| `GW_INTERVAL` | ❌ | `50` 截断数量，方式仓库无限膨胀 |


## ⚙️ 工作原理

1. **启动时 (Restore)**: 容器启动前，Wrapper 会自动 `git clone` 仓库，并将指定文件覆盖到容器目录。
2. **运行时 (Backup)**: 后台进程每隔 `GW_INTERVAL` 秒，将容器目录的变化 Commit 并 Push 回仓库。
3. **销毁时 (Graceful Shutdown)**: 收到 `SIGTERM` 信号时，Wrapper 会等待主进程结束，并执行**最后一次强制推送**，确保数据不丢失。
4. **Entrypoint 继承**: 构建脚本会自动探测原镜像的 `ENTRYPOINT` (如 MySQL 的启动脚本)，确保原有的初始化逻辑不受影响。

## ⚠️ 注意事项

- **大文件**: 不建议用于存储大量二进制文件（数据库文件、视频），Git 会膨胀导致启动缓慢。
- **.gitignore**: 建议在 Git 仓库根目录放一个 `.gitignore`，排除 `node_modules` 等无用文件。
