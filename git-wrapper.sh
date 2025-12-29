#!/bin/bash
set -e

# ==================== 0. 环境变量 ====================
# 用户需填入干净的 URL (不带 username@)
REPO_URL="$GW_REPO_URL"
USERNAME="${GW_USER:-git}" 
PAT="$GW_PAT"
BRANCH="${GW_BRANCH:-main}"
INTERVAL="${GW_INTERVAL:-300}"
SYNC_MAP="$GW_SYNC_MAP"

# 从 Dockerfile 传来的原镜像配置
ORIGINAL_ENTRYPOINT="$GW_ORIGINAL_ENTRYPOINT"
ORIGINAL_CMD="$GW_ORIGINAL_CMD"
ORIGINAL_WORKDIR="$GW_ORIGINAL_WORKDIR"

GIT_STORE="/git-store"

# ==================== 1. 准备工作 ====================
if [ -z "$REPO_URL" ] || [ -z "$PAT" ] || [ -z "$SYNC_MAP" ]; then
    echo "[GitWrapper] [ERROR] Missing env vars: GW_REPO_URL, GW_PAT, or GW_SYNC_MAP."
fi

# URL 协议探测与清洗
case "$REPO_URL" in
    http://*) PROTOCOL="http://" ;;
    *)        PROTOCOL="https://" ;;
esac
CLEAN_URL=$(echo "$REPO_URL" | sed -E "s|^(https?://)||")
AUTH_URL="${PROTOCOL}${USERNAME}:${PAT}@${CLEAN_URL}"

# ==================== 2. 核心逻辑 ====================

restore_data() {
    echo "[GitWrapper] >>> Initializing..."
    
    git config --global --add safe.directory "$GIT_STORE"
    git config --global user.name "${USERNAME:-BackupBot}"
    git config --global user.email "${USERNAME:-bot}@wrapper.local"
    git config --global init.defaultBranch "$BRANCH"

    if [ -d "$GIT_STORE" ]; then rm -rf "$GIT_STORE"; fi
    
    # 允许 Clone 失败 (应对空仓库)
    git clone "$AUTH_URL" "$GIT_STORE" > /dev/null 2>&1 || true

    if [ ! -d "$GIT_STORE/.git" ]; then
        echo "[GitWrapper] [ERROR] Clone failed. Check URL/PAT."
        return
    fi

    cd "$GIT_STORE"

    # 空仓库初始化
    if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
        echo "[GitWrapper] [WARN] Empty repo detected. Initializing '$BRANCH'..."
        git checkout -b "$BRANCH" 2>/dev/null || true
        git commit --allow-empty -m "Init"
        git push -u origin "$BRANCH"
    else
        git checkout "$BRANCH" 2>/dev/null || true
    fi

    # 还原文件
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
            
            # === [还原] 脱掉隐身衣 ===
            # 将 .git_backup_cloak 改回 .git，恢复子项目的 Git 功能
            if [ -d "$LOCAL_PATH" ]; then
                find "$LOCAL_PATH" -name ".git_backup_cloak" -type d -prune -exec sh -c 'mv "$1" "${1%_backup_cloak}"' _ {} \; 2>/dev/null || true
            fi
        fi
    done
}

backup_data() {
    if [ ! -d "$GIT_STORE/.git" ]; then return; fi
    
    IFS=';' read -ra MAPPINGS <<< "$SYNC_MAP"
    for MAPPING in "${MAPPINGS[@]}"; do
        REMOTE_REL=$(echo "$MAPPING" | cut -d':' -f1)
        REMOTE_FULL="$GIT_STORE/$REMOTE_REL"
        LOCAL_PATH="$(echo "$MAPPING" | cut -d':' -f2)"

        if [ -e "$LOCAL_PATH" ]; then
            mkdir -p "$(dirname "$REMOTE_FULL")"
            rm -rf "$REMOTE_FULL"
            
            # 拷贝文件
            cp -r "$LOCAL_PATH" "$REMOTE_FULL"

            # === [备份] 穿上隐身衣 ===
            # 将 .git 改名为 .git_backup_cloak，欺骗父 Git 把它当普通文件夹备份
            if [ -d "$REMOTE_FULL" ]; then
                 find "$REMOTE_FULL" -name ".git" -type d -prune -exec mv '{}' '{}_backup_cloak' \; 2>/dev/null || true
            fi
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

# ==================== 3. 启动流程 ====================

restore_data

# 后台同步进程
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

# ==================== 4. 智能启动 (显微镜模式) ====================

echo "[GitWrapper] >>> Starting App..."
echo "[GitWrapper] [DEBUG] WorkDir:    '$ORIGINAL_WORKDIR'"
echo "[GitWrapper] [DEBUG] Entrypoint: '$ORIGINAL_ENTRYPOINT'"
echo "[GitWrapper] [DEBUG] CMD:        '$ORIGINAL_CMD'"
echo "[GitWrapper] [DEBUG] Args:       '$*'"

# --- 切回原目录 ---
if [ -n "$ORIGINAL_WORKDIR" ]; then
    cd "$ORIGINAL_WORKDIR" || cd /
else
    cd /
fi

# --- 拼接逻辑 ---
# 如果用户运行时传了参数($*)，覆盖原 CMD；否则使用原 CMD
if [ -n "$*" ]; then
    FINAL_ARGS="$*"
else
    FINAL_ARGS="$ORIGINAL_CMD"
fi

# 拼接 Entrypoint 和 Args
if [ -n "$ORIGINAL_ENTRYPOINT" ]; then
    CMD_STR="$ORIGINAL_ENTRYPOINT $FINAL_ARGS"
else
    CMD_STR="$FINAL_ARGS"
fi

if [ -z "$CMD_STR" ]; then
    echo "[GitWrapper] [FATAL] No command specified! Base image has no ENTRYPOINT and CMD."
    exit 1
fi

echo "[GitWrapper] [DEBUG] Executing: $CMD_STR"

# set -m: 启用作业控制
# 2>&1: 强制显示错误日志
set -m
$CMD_STR 2>&1 &
APP_PID=$!

echo "[GitWrapper] [DEBUG] PID: $APP_PID"
sleep 3

# 存活检测
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
