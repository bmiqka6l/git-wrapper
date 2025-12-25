#!/bin/bash
set -e

# ==================== 配置 ====================
REPO_URL="$GW_REPO_URL"
USERNAME="${GW_USER:-git}" 
PAT="$GW_PAT"
BRANCH="${GW_BRANCH:-main}"
INTERVAL="${GW_INTERVAL:-300}"
SYNC_MAP="$GW_SYNC_MAP"
ORIGINAL_ENTRYPOINT="$GW_ORIGINAL_ENTRYPOINT"

GIT_STORE="/git-store"


if [ -z "$REPO_URL" ] || [ -z "$PAT" ] || [ -z "$SYNC_MAP" ]; then
    echo "[GitWrapper] [ERROR] Missing required env vars."
fi

# 只去除开头的 https:// (防止重复)，不做任何其他正则替换
CLEAN_URL=$(echo "$REPO_URL" | sed "s|^https://||")
AUTH_URL="https://${USERNAME}:${PAT}@${CLEAN_URL}"

# ==================== 2. 核心功能 ====================

restore_data() {
    echo "[GitWrapper] >>> Initializing..."
    
    git config --global --add safe.directory "$GIT_STORE"
    git config --global user.name "${USERNAME:-BackupBot}"
    git config --global user.email "${USERNAME:-bot}@wrapper.local"
    git config --global init.defaultBranch "$BRANCH"

    if [ -d "$GIT_STORE" ]; then rm -rf "$GIT_STORE"; fi
    
    # Clone 失败也不退出 (可能是空仓库)
    echo "[GitWrapper] Cloning from: https://${USERNAME}:***@${CLEAN_URL}"
    git clone "$AUTH_URL" "$GIT_STORE" > /dev/null 2>&1 || true

    if [ ! -d "$GIT_STORE/.git" ]; then
        echo "[GitWrapper] [ERROR] Clone failed. Check your URL/PAT."
        # 这里为了防止容器无限重启，我们不 exit 1，而是打印错误
        return
    fi

    cd "$GIT_STORE"

    # --- 空仓库自动初始化 ---
    if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
        echo "[GitWrapper] [WARN] Empty repo. Initializing branch '$BRANCH'..."
        git checkout -b "$BRANCH" 2>/dev/null || true
        git commit --allow-empty -m "Init"
        git push -u origin "$BRANCH"
    else
        git checkout "$BRANCH" 2>/dev/null || true
    fi

    # --- 还原文件 ---
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
        fi
    done
}

backup_data() {
    if [ ! -d "$GIT_STORE/.git" ]; then return; fi
    
    # 简单的两步：同步文件 -> 提交推送
    IFS=';' read -ra MAPPINGS <<< "$SYNC_MAP"
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

    cd "$GIT_STORE" || return
    if [ -n "$(git status --porcelain)" ]; then
        echo "[GitWrapper] Syncing..."
        git add .
        git commit -m "Backup: $(date '+%Y-%m-%d %H:%M:%S')" > /dev/null
        git pull --rebase origin "$BRANCH" > /dev/null 2>&1 || true
        git push origin "$BRANCH" > /dev/null 2>&1
    fi
}

# ==================== 3. 启动逻辑 ====================

restore_data

(
    while true; do
        sleep "$INTERVAL"
        backup_data
    done
) &
SYNC_PID=$!

shutdown_handler() {
    echo "[GitWrapper] !!! Shutting down..."
    if kill -0 "$APP_PID" 2>/dev/null; then
        kill -SIGTERM "$APP_PID"
        wait "$APP_PID"
    fi
    kill -SIGTERM "$SYNC_PID" 2>/dev/null
    backup_data
    exit 0
}
trap 'shutdown_handler' SIGTERM SIGINT

# ==================== 4. 显微镜 Debug 模式 ====================

echo "[GitWrapper] >>> Starting Main App..."
echo "[GitWrapper] [DEBUG] Args: $*"
echo "[GitWrapper] [DEBUG] Original Entrypoint: $ORIGINAL_ENTRYPOINT"

# 拼接命令
if [ -n "$ORIGINAL_ENTRYPOINT" ]; then
    CMD_STR="$ORIGINAL_ENTRYPOINT $*"
else
    CMD_STR="$*"
fi

if [ -z "$CMD_STR" ]; then
    echo "[GitWrapper] [FATAL] No command! Base image has no ENTRYPOINT and CMD is empty."
    exit 1
fi

echo "[GitWrapper] [DEBUG] Executing: $CMD_STR"

# 启用作业控制，防止后台进程被静默回收
set -m
# 关键：2>&1 确保错误日志能打出来
$CMD_STR 2>&1 &
APP_PID=$!

echo "[GitWrapper] [DEBUG] PID: $APP_PID"
sleep 3

if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "[GitWrapper] [FATAL] App died immediately!"
    wait "$APP_PID"
    EXIT_CODE=$?
    echo "[GitWrapper] [FATAL] Exit Code: $EXIT_CODE"
    exit $EXIT_CODE
else
    echo "[GitWrapper] [SUCCESS] App is running."
fi

wait "$APP_PID"
