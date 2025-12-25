#!/bin/bash
set -e

# ==================== 配置与命名空间 ====================
# 使用 GW_ 前缀避免污染业务环境变量
REPO_URL="$GW_REPO_URL"
USERNAME="$GW_USER"
PAT="$GW_PAT"
BRANCH="${GW_BRANCH:-main}"
INTERVAL="${GW_INTERVAL:-300}"
SYNC_MAP="$GW_SYNC_MAP"
ORIGINAL_ENTRYPOINT="$GW_ORIGINAL_ENTRYPOINT"

GIT_STORE="/git-store"

# ==================== 校验逻辑 ====================
if [ -z "$REPO_URL" ] || [ -z "$PAT" ] || [ -z "$SYNC_MAP" ]; then
    echo "[GitWrapper] Error: Missing required env vars (GW_REPO_URL, GW_PAT, or GW_SYNC_MAP)."
    # 不退出，防止彻底卡死业务，但会报错
fi

# 构造带 Auth 的 URL (隐藏 Token)
AUTH_URL=$(echo "$REPO_URL" | sed "s|https://|https://${USERNAME}:${PAT}@|")

# ==================== 核心函数 ====================

restore_data() {
    echo "[GitWrapper] >>> Initializing Git Storage..."
    
    # 配置 Git 用户
    git config --global user.name "${USERNAME:-BackupBot}"
    git config --global user.email "${USERNAME:-bot}@wrapper.local"
    # 防止因目录属主问题报错 (git safe directory)
    git config --global --add safe.directory "$GIT_STORE"

    if [ -d "$GIT_STORE" ]; then rm -rf "$GIT_STORE"; fi
    
    echo "[GitWrapper] >>> Cloning branch '$BRANCH'..."
    git clone --branch "$BRANCH" "$AUTH_URL" "$GIT_STORE" 2>/dev/null || \
    git clone "$AUTH_URL" "$GIT_STORE" # 如果指定分支不存在，尝试默认clone

    IFS=';' read -ra MAPPINGS <<< "$SYNC_MAP"
    for MAPPING in "${MAPPINGS[@]}"; do
        REMOTE_REL=$(echo "$MAPPING" | cut -d':' -f1)
        REMOTE_PATH="$GIT_STORE/$REMOTE_REL"
        LOCAL_PATH="$(echo "$MAPPING" | cut -d':' -f2)"

        if [ -e "$REMOTE_PATH" ]; then
            echo "[GitWrapper] Restore: $REMOTE_REL -> $LOCAL_PATH"
            mkdir -p "$(dirname "$LOCAL_PATH")"
            rm -rf "$LOCAL_PATH"
            cp -r "$REMOTE_PATH" "$LOCAL_PATH"
        else
            echo "[GitWrapper] Remote path '$REMOTE_REL' not found. Using local version."
        fi
    done
}

backup_data() {
    IFS=';' read -ra MAPPINGS <<< "$SYNC_MAP"
    
    # 1. 收集：从容器 -> Git仓库
    for MAPPING in "${MAPPINGS[@]}"; do
        REMOTE_REL=$(echo "$MAPPING" | cut -d':' -f1)
        REMOTE_FULL="$GIT_STORE/$REMOTE_REL"
        LOCAL_PATH="$(echo "$MAPPING" | cut -d':' -f2)"

        if [ -e "$LOCAL_PATH" ]; then
            mkdir -p "$(dirname "$REMOTE_FULL")"
            rm -rf "$REMOTE_FULL"
            cp -r "$LOCAL_PATH" "$REMOTE_FULL"
        fi
    done

    # 2. 推送：Git仓库 -> 远程
    cd "$GIT_STORE" || exit
    if [ -n "$(git status --porcelain)" ]; then
        echo "[GitWrapper] Changes detected at $(date '+%H:%M:%S'), syncing..."
        git add .
        git commit -m "Backup: $(date '+%Y-%m-%d %H:%M:%S')" > /dev/null
        
        # 激进策略：Rebase 拉取，如果有冲突优先保留本地（theirs 指的是 rebase 里的 upstream，这里我们希望 push 成功，通常用 ours 这里的语境比较复杂，简单用 rebase 即可）
        git pull --rebase origin "$BRANCH" > /dev/null 2>&1 || echo "[GitWrapper] Warning: Pull conflict."
        
        git push origin "$BRANCH" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "[GitWrapper] Push success."
        else
            echo "[GitWrapper] Push failed."
        fi
    fi
}

# ==================== 生命周期管理 ====================

# 1. 启动时还原
restore_data

# 2. 启动后台同步循环
(
    while true; do
        sleep "$INTERVAL"
        backup_data
    done
) &
SYNC_PID=$!

# 3. 准备启动主程序
echo "[GitWrapper] >>> Starting Application..."

# 信号处理：收到停止信号时，先杀应用，再做最后一次备份
shutdown_handler() {
    echo "[GitWrapper] !!! SIGTERM/SIGINT received."
    
    # 转发信号给主进程 (如果它还在跑)
    if kill -0 "$APP_PID" 2>/dev/null; then
        kill -SIGTERM "$APP_PID"
        wait "$APP_PID"
    fi

    echo "[GitWrapper] !!! Performing final backup..."
    kill -SIGTERM "$SYNC_PID" 2>/dev/null
    backup_data
    echo "[GitWrapper] !!! Goodbye."
    exit 0
}
trap 'shutdown_handler' SIGTERM SIGINT

# 4. 智能启动逻辑 (处理复杂的 Entrypoint)
if [ -n "$ORIGINAL_ENTRYPOINT" ]; then
    echo "[GitWrapper] Executing original entrypoint: $ORIGINAL_ENTRYPOINT"
    # 注意：这里并不加引号 "$ORIGINAL_ENTRYPOINT"，允许 shell 拆分参数
    # 例如 "docker-entrypoint.sh" 或 "python3 app.py"
    $ORIGINAL_ENTRYPOINT "$@" &
else
    "$@" &
fi
APP_PID=$!

# 5. 挂起等待
wait "$APP_PID"