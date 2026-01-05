#!/bin/bash
set -e

# ==================== 0. 环境变量 ====================
REPO_URL="$GW_REPO_URL"
USERNAME="${GW_USER:-git}" 
PAT="$GW_PAT"
BRANCH="${GW_BRANCH:-main}"
INTERVAL="${GW_INTERVAL:-300}"
SYNC_MAP="$GW_SYNC_MAP"

# === 截断配置 ===
# 当提交数超过这个值时，重置历史为 1 个提交
# 设为 0 则不限制
HISTORY_LIMIT="${GW_HISTORY_LIMIT:-50}"

# 继承参数
ORIGINAL_ENTRYPOINT="$GW_ORIGINAL_ENTRYPOINT"
ORIGINAL_CMD="$GW_ORIGINAL_CMD"
ORIGINAL_WORKDIR="$GW_ORIGINAL_WORKDIR"

GIT_STORE="/git-store"

# ==================== 1. 准备工作 ====================
init_config() {
    if [ -z "$REPO_URL" ] || [ -z "$PAT" ] || [ -z "$SYNC_MAP" ]; then
        echo "[GitWrapper] [ERROR] Missing required environment variables!"
        echo "[GitWrapper] [ERROR] Required: GW_REPO_URL, GW_PAT, GW_SYNC_MAP"
        echo "[GitWrapper] [WARN] Wrapper will start container without sync functionality"
        return 1
    fi

    case "$REPO_URL" in
        http://*) PROTOCOL="http://" ;;
        *)        PROTOCOL="https://" ;;
    esac
    CLEAN_URL=$(echo "$REPO_URL" | sed -E "s|^(https?://)||")
    AUTH_URL="${PROTOCOL}${USERNAME}:${PAT}@${CLEAN_URL}"
    
    return 0
}

# ==================== 2. 核心逻辑 ====================

restore_data() {
    echo "[GitWrapper] >>> Initializing..."
    git config --global --add safe.directory "$GIT_STORE"
    git config --global user.name "${USERNAME:-BackupBot}"
    git config --global user.email "${USERNAME:-bot}@wrapper.local"
    git config --global init.defaultBranch "$BRANCH"

    if [ -d "$GIT_STORE" ]; then rm -rf "$GIT_STORE"; fi
    
    git clone "$AUTH_URL" "$GIT_STORE" > /dev/null 2>&1 || true

    if [ ! -d "$GIT_STORE/.git" ]; then
        echo "[GitWrapper] [ERROR] Clone failed."
        return
    fi

    cd "$GIT_STORE"

    # 空仓库初始化
    if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
        echo "[GitWrapper] [WARN] Empty repo. Initializing..."
        git checkout -b "$BRANCH" 2>/dev/null || true
        git commit --allow-empty -m "Init"
        git push -u origin "$BRANCH"
    else
        git checkout "$BRANCH" 2>/dev/null || true
    fi

    IFS=';' read -ra MAPPINGS <<< "$SYNC_MAP"
    for MAPPING in "${MAPPINGS[@]}"; do
        # 解析映射
        IFS=':' read -ra PARTS <<< "$MAPPING"
        local path_type=""
        local remote_rel=""
        local local_path=""
        
        if [ ${#PARTS[@]} -eq 3 ]; then
            # 格式: type:remote_rel:local_path
            path_type="${PARTS[0]}"
            remote_rel="${PARTS[1]}"
            local_path="${PARTS[2]}"
        elif [ ${#PARTS[@]} -eq 2 ]; then
            # 格式: remote_rel:local_path (自动判断)
            remote_rel="${PARTS[0]}"
            local_path="${PARTS[1]}"
            # 通过扩展名猜测
            if [[ "$local_path" =~ \.[a-zA-Z0-9]+$ ]]; then
                path_type="file"
            else
                path_type="dir"
            fi
        else
            echo "[GitWrapper] [ERROR] Invalid SYNC_MAP format: $MAPPING"
            continue
        fi
        
        REMOTE_PATH="$GIT_STORE/$remote_rel"

        if [ -e "$REMOTE_PATH" ]; then
            echo "[GitWrapper] Restore: $remote_rel -> $local_path"
            mkdir -p "$(dirname "$local_path")"
            rm -rf "$local_path"
            cp -r "$REMOTE_PATH" "$local_path"
            # [还原] 脱隐身衣
            if [ -d "$local_path" ]; then
                find "$local_path" -name ".git_backup_cloak" -type d -prune -exec sh -c 'mv "$1" "${1%_backup_cloak}"' _ {} \; 2>/dev/null || true
            fi
        else
            # Git 仓库中路径不存在（新容器初始化）
            if [ "$path_type" = "dir" ]; then
                # 目录类型：预先创建，防止应用写入时报错
                echo "[GitWrapper] Creating directory for app: $local_path"
                mkdir -p "$local_path"
            else
                # 文件类型：跳过，不创建文件
                echo "[GitWrapper] Skipping file creation, let app initialize: $local_path"
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
            cp -r "$LOCAL_PATH" "$REMOTE_FULL"
            # [备份] 穿隐身衣 (处理嵌套Git)
            if [ -d "$REMOTE_FULL" ]; then
                 find "$REMOTE_FULL" -name ".git" -type d -prune -exec mv '{}' '{}_backup_cloak' \; 2>/dev/null || true
            fi
        fi
    done

    cd "$GIT_STORE" || return
    
    # 检查变更
    if [ -n "$(git status --porcelain)" ]; then
        echo "[GitWrapper] Syncing..."
        git add .
        git commit -m "Backup: $(date '+%Y-%m-%d %H:%M:%S')" > /dev/null
    else
        echo "[GitWrapper] Skip Sync"
        return # 无变更不检查截断
    fi

    # ==================== 🚨 全量截断逻辑 (History Reset) ====================
    COMMIT_COUNT=$(git rev-list --count HEAD)

    echo "[GitWrapper] [RESET] Count $COMMIT_COUNT, $HISTORY_LIMIT."
    
    if [ "$HISTORY_LIMIT" -gt 0 ] && [ "$COMMIT_COUNT" -gt "$HISTORY_LIMIT" ]; then
        echo "[GitWrapper] [RESET] Count $COMMIT_COUNT > $HISTORY_LIMIT. Resetting history to 1 commit..."
        
        CURRENT_BRANCH=$(git branch --show-current)
        
        # 1. 孤儿分支: 抛弃父节点，保留文件
        git checkout --orphan temp_reset_branch > /dev/null 2>&1
        
        # 2. 重新提交所有文件
        git add -A
        git commit -m "Reset History: Snapshot at $(date '+%Y-%m-%d %H:%M:%S')" > /dev/null
        
        # 3. 替换旧分支
        git branch -D "$CURRENT_BRANCH" > /dev/null 2>&1
        git branch -m "$CURRENT_BRANCH"
        
        # 4. 强推覆盖
        echo "[GitWrapper] Force pushing new snapshot..."
        if git push -f origin "$CURRENT_BRANCH" > /dev/null 2>&1; then
             echo "[GitWrapper] [SUCCESS] History reset complete."
        else
             echo "[GitWrapper] [ERROR] Force push failed."
        fi
    else
        # 正常推送
        git pull --rebase origin "$BRANCH" > /dev/null 2>&1 || true
        git push origin "$BRANCH" > /dev/null 2>&1
    fi
}

# ==================== 3. 启动流程 ====================

if init_config; then
    # 配置成功，启用同步功能
    restore_data

    (
        while true; do
            sleep "$INTERVAL"
            backup_data
        done
    ) &
    SYNC_PID=$!
else
    # 配置失败，跳过同步功能
    echo "[GitWrapper] [WARN] Sync functionality disabled due to configuration error"
    echo "[GitWrapper] [INFO] Container will start normally without backup/restore"
    SYNC_PID=""
fi

shutdown_handler() {
    echo "[GitWrapper] !!! Shutting down..."
    if kill -0 "$APP_PID" 2>/dev/null; then
        kill -SIGTERM "$APP_PID"
        wait "$APP_PID"
    fi
    if [ -n "$SYNC_PID" ]; then
        kill -SIGTERM "$SYNC_PID" 2>/dev/null
        backup_data
    fi
    exit 0
}
trap 'shutdown_handler' SIGTERM SIGINT

# ==================== 4. 显微镜启动 ====================

echo "[GitWrapper] >>> Starting App..."
echo "[GitWrapper] [DEBUG] WorkDir:    '$ORIGINAL_WORKDIR'"
echo "[GitWrapper] [DEBUG] CMD:        '$ORIGINAL_CMD'"

if [ -n "$ORIGINAL_WORKDIR" ]; then
    cd "$ORIGINAL_WORKDIR" || cd /
else
    cd /
fi

if [ -n "$*" ]; then
    FINAL_ARGS="$*"
else
    FINAL_ARGS="$ORIGINAL_CMD"
fi

if [ -n "$ORIGINAL_ENTRYPOINT" ]; then
    CMD_STR="$ORIGINAL_ENTRYPOINT $FINAL_ARGS"
else
    CMD_STR="$FINAL_ARGS"
fi

if [ -z "$CMD_STR" ]; then
    echo "[GitWrapper] [FATAL] No command specified!"
    exit 1
fi

echo "[GitWrapper] [DEBUG] Executing: $CMD_STR"

set -m
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
