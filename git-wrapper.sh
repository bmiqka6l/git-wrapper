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
HISTORY_LIMIT="${GW_HISTORY_LIMIT:-50}"

# 继承参数
ORIGINAL_ENTRYPOINT="$GW_ORIGINAL_ENTRYPOINT"
ORIGINAL_CMD="$GW_ORIGINAL_CMD"
ORIGINAL_WORKDIR="$GW_ORIGINAL_WORKDIR"

GIT_STORE="/git-store"
APP_PID=""
SYNC_PID=""

# ==================== 1. 准备工作 ====================
init_config() {
    if [ -z "$REPO_URL" ] || [ -z "$PAT" ] || [ -z "$SYNC_MAP" ]; then
        echo "[GitWrapper] [ERROR] Missing required environment variables!"
        echo "[GitWrapper] [ERROR] Required: GW_REPO_URL, GW_PAT, GW_SYNC_MAP"
        return 1
    fi

    # 1. 协议标准化
    case "$REPO_URL" in
    http://*) PROTOCOL="http://" ;;
    *) PROTOCOL="https://" ;;
    esac
    CLEAN_URL=$(echo "$REPO_URL" | sed -E "s|^(https?://)||")
    
    # 2. PAT URL 编码 (解决 @ : / + 等特殊字符问题)
    local ENCODED_PAT=$(echo "$PAT" | sed 's/%/%25/g' | sed 's/@/%40/g' | sed 's/:/%3A/g' | sed 's|/|%2F|g' | sed 's/+/%2B/g')
    
    # 3. USERNAME URL 编码
    local ENCODED_USER=$(echo "$USERNAME" | sed 's/%/%25/g' | sed 's/@/%40/g' | sed 's/:/%3A/g' | sed 's|/|%2F|g' | sed 's/+/%2B/g')

    AUTH_URL="${PROTOCOL}${ENCODED_USER}:${ENCODED_PAT}@${CLEAN_URL}"

    return 0
}

# ==================== 2. 核心逻辑 ====================

restore_data() {
    echo "[GitWrapper] >>> Initializing & Restoring..."
    
    # Git 全局配置
    git config --global --add safe.directory "$GIT_STORE"
    git config --global user.name "${USERNAME:-BackupBot}"
    git config --global user.email "${USERNAME:-bot}@wrapper.local"
    git config --global init.defaultBranch "$BRANCH"

    # ========================================================
    # 阶段 1: Clone 到临时目录 (避免非空目录报错)
    # ========================================================
    
    local TEMP_CLONE_DIR="/tmp/git-clone-temp-$(date +%s)-$RANDOM"
    echo "[GitWrapper] Cloning to temporary location..."

    if ! git clone "$AUTH_URL" "$TEMP_CLONE_DIR"; then
        echo "[GitWrapper] [FATAL] Git Clone Failed!"
        echo "[GitWrapper] [FATAL] Please check Network or Token validity."
        rm -rf "$TEMP_CLONE_DIR"
        exit 1
    fi

    # 准备目标目录
    if [ ! -d "$GIT_STORE" ]; then
        mkdir -p "$GIT_STORE"
    else
        echo "[GitWrapper] Cleaning existing GIT_STORE..."
        shopt -s dotglob 2>/dev/null || true
        rm -rf "$GIT_STORE"/*
        shopt -u dotglob 2>/dev/null || true
    fi

    # 移动内容
    echo "[GitWrapper] Moving repository to $GIT_STORE"
    shopt -s dotglob 2>/dev/null || true
    if ! mv "$TEMP_CLONE_DIR"/* "$GIT_STORE/"; then
        echo "[GitWrapper] [FATAL] Failed to move files to $GIT_STORE"
        rm -rf "$TEMP_CLONE_DIR"
        exit 1
    fi
    shopt -u dotglob 2>/dev/null || true
    rm -rf "$TEMP_CLONE_DIR"

    if [ ! -d "$GIT_STORE/.git" ]; then
        echo "[GitWrapper] [FATAL] .git directory missing in $GIT_STORE after move."
        exit 1
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

    # ========================================================
    # 阶段 2: 还原文件 (解决 Resource busy 问题)
    # ========================================================
    IFS=';' read -ra MAPPINGS <<<"$SYNC_MAP"
    for MAPPING in "${MAPPINGS[@]}"; do
        IFS=':' read -ra PARTS <<<"$MAPPING"
        local path_type=""
        local remote_rel=""
        local local_path=""

        if [ ${#PARTS[@]} -eq 3 ]; then
            path_type="${PARTS[0]}"
            remote_rel="${PARTS[1]}"
            local_path="${PARTS[2]}"
        elif [ ${#PARTS[@]} -eq 2 ]; then
            remote_rel="${PARTS[0]}"
            local_path="${PARTS[1]}"
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
            
            # 确保父目录存在
            if [ ! -d "$(dirname "$local_path")" ]; then
                mkdir -p "$(dirname "$local_path")"
            fi

            # 🚨 核心修复：如果是目录（或挂载卷），清空内容而不是删除目录
            if [ -d "$local_path" ]; then
                echo "[GitWrapper] [DEBUG] Target is directory/volume, cleaning contents..."
                
                # 开启 dotglob 以删除隐藏文件
                shopt -s dotglob 2>/dev/null || true
                
                # 清空内容 (保留目录外壳)
                rm -rf "$local_path"/*
                
                # 复制内容 (注意结尾斜杠)
                if [ -d "$REMOTE_PATH" ]; then
                     cp -r "$REMOTE_PATH"/* "$local_path"/
                else
                     # 远程是文件，本地是目录（罕见情况），强制覆盖
                     cp -r "$REMOTE_PATH" "$local_path"/
                fi
                
                shopt -u dotglob 2>/dev/null || true
            else
                # 普通文件或路径不存在，直接覆盖
                rm -rf "$local_path"
                cp -r "$REMOTE_PATH" "$local_path"
            fi

            # [还原] 脱隐身衣
            if [ -d "$local_path" ]; then
                find "$local_path" -name ".git_backup_cloak" -type d -prune -exec sh -c 'mv "$1" "${1%_backup_cloak}"' _ {} \; 2>/dev/null || true
            fi
        else
            # Git 中没有此文件/目录
            if [ "$path_type" = "dir" ]; then
                if [ ! -d "$local_path" ]; then
                    echo "[GitWrapper] Creating directory for app: $local_path"
                    mkdir -p "$local_path"
                fi
            else
                echo "[GitWrapper] Skipping file creation: $local_path"
            fi
        fi
    done
}

backup_data() {
    echo "[GitWrapper] [DEBUG] ========================================"
    echo "[GitWrapper] [DEBUG] Starting backup cycle at $(date '+%Y-%m-%d %H:%M:%S')"

    if [ ! -d "$GIT_STORE/.git" ]; then 
        echo "[GitWrapper] [ERROR] .git directory missing in $GIT_STORE. Aborting backup."
        return 0
    fi

    IFS=';' read -ra MAPPINGS <<<"$SYNC_MAP"
    for MAPPING in "${MAPPINGS[@]}"; do
        if [[ "$MAPPING" == *:* ]]; then
             IFS=':' read -ra PARTS <<<"$MAPPING"
             local remote_rel
             local local_path
             if [ ${#PARTS[@]} -eq 3 ]; then
                 remote_rel="${PARTS[1]}"
                 local_path="${PARTS[2]}"
             elif [ ${#PARTS[@]} -eq 2 ]; then
                 remote_rel="${PARTS[0]}"
                 local_path="${PARTS[1]}"
             fi
        else
            continue
        fi

        REMOTE_FULL="$GIT_STORE/$remote_rel"

        if [ -e "$local_path" ]; then
            echo "[GitWrapper] [DEBUG] Copying: $local_path -> $REMOTE_FULL"
            mkdir -p "$(dirname "$REMOTE_FULL")"
            rm -rf "$REMOTE_FULL"
            
            if cp -r "$local_path" "$REMOTE_FULL"; then
                echo "[GitWrapper] [DEBUG] Copy success."
            else
                echo "[GitWrapper] [ERROR] Copy failed for $local_path"
            fi
            
            # [备份] 穿隐身衣
            if [ -d "$REMOTE_FULL" ]; then
                find "$REMOTE_FULL" -name ".git" -type d -prune -exec mv '{}' '{}_backup_cloak' \; 2>/dev/null || true
            fi
        else
            echo "[GitWrapper] [WARN] Local path not found, skipping copy: $local_path"
        fi
    done

    cd "$GIT_STORE" || { echo "[GitWrapper] [ERROR] Failed to enter $GIT_STORE"; return 0; }

    echo "[GitWrapper] [DEBUG] Checking Git status..."
    local GIT_STATUS
    GIT_STATUS=$(git status --porcelain)

    if [ -n "$GIT_STATUS" ]; then
        echo "[GitWrapper] [INFO] Changes detected:"
        # 逐行打印发生变化的文件
        echo "$GIT_STATUS" | while read -r line; do
            echo "[GitWrapper] [DEBUG]   -> $line"
        done

        echo "[GitWrapper] [DEBUG] Adding changes to index..."
        git add .

        echo "[GitWrapper] [DEBUG] Committing..."
        # 移除了 >/dev/null 暴露真实错误
        if git commit -m "Backup: $(date '+%Y-%m-%d %H:%M:%S')"; then
            echo "[GitWrapper] [INFO] Commit successful."
        else
            echo "[GitWrapper] [ERROR] Commit failed!"
        fi
    else
        echo "[GitWrapper] [INFO] No changes detected. Skipping commit and push."
        echo "[GitWrapper] [DEBUG] ========================================"
        return 0
    fi

    # 截断逻辑
    COMMIT_COUNT=$(git rev-list --count HEAD 2>/dev/null || echo 0)
    echo "[GitWrapper] [DEBUG] Current commit count: $COMMIT_COUNT / Limit: $HISTORY_LIMIT"

    if [ "$HISTORY_LIMIT" -gt 0 ] && [ "$COMMIT_COUNT" -gt "$HISTORY_LIMIT" ]; then
        echo "[GitWrapper] [INFO] Limit reached. Resetting history..."
        CURRENT_BRANCH=$(git branch --show-current)
        git checkout --orphan temp_reset_branch >/dev/null 2>&1
        git add -A
        
        if git commit -m "Reset History: Snapshot at $(date '+%Y-%m-%d %H:%M:%S')"; then
            echo "[GitWrapper] [DEBUG] Reset commit created."
        else
            echo "[GitWrapper] [ERROR] Reset commit failed."
        fi
        
        git branch -D "$CURRENT_BRANCH" >/dev/null 2>&1 || true
        git branch -m "$CURRENT_BRANCH"

        echo "[GitWrapper] [DEBUG] Force pushing to origin..."
        # 移除了 >/dev/null 2>&1 暴露真实网络/权限错误
        if git push -f origin "$CURRENT_BRANCH"; then
            echo "[GitWrapper] [INFO] Force push successful."
        else
            echo "[GitWrapper] [ERROR] Force push failed! Check permissions or network."
        fi
    else
        echo "[GitWrapper] [DEBUG] Pulling latest from origin (rebase)..."
        # 暴露 pull 过程中的冲突或报错
        if ! git pull --rebase origin "$BRANCH"; then
            echo "[GitWrapper] [WARN] Git pull failed or encountered conflicts!"
        fi

        echo "[GitWrapper] [DEBUG] Pushing to origin..."
        # 暴露 push 报错
        if git push origin "$BRANCH"; then
            echo "[GitWrapper] [INFO] Push successful."
        else
            echo "[GitWrapper] [ERROR] Push failed! Check permissions or network."
        fi
    fi
    
    echo "[GitWrapper] [DEBUG] Backup cycle finished."
    echo "[GitWrapper] [DEBUG] ========================================"
}

shutdown_handler() {
    echo "[GitWrapper] !!! Shutting down..."
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill -SIGTERM "$APP_PID"
        wait "$APP_PID"
    fi
    if [ -n "$SYNC_PID" ]; then
        kill -SIGTERM "$SYNC_PID" 2>/dev/null
        # 退出前做最后一次备份
        backup_data
    fi
    exit 0
}

# ==================== 4. 显微镜启动 ====================

# ==================== 4. 显微镜启动 ====================

start_main_app() {
    echo "[GitWrapper] >>> Starting App..."
    echo "[GitWrapper] [DEBUG] -------------------------------------"
    echo "[GitWrapper] [DEBUG] Raw ORIGINAL_ENTRYPOINT: '$ORIGINAL_ENTRYPOINT'"
    echo "[GitWrapper] [DEBUG] Raw ORIGINAL_CMD:        '$ORIGINAL_CMD'"
    echo "[GitWrapper] [DEBUG] Raw ORIGINAL_WORKDIR:    '$ORIGINAL_WORKDIR'"
    echo "[GitWrapper] [DEBUG] -------------------------------------"
    
    if [ -n "$ORIGINAL_WORKDIR" ]; then
        echo "[GitWrapper] [DEBUG] Changing directory to: $ORIGINAL_WORKDIR"
        cd "$ORIGINAL_WORKDIR" || cd /
    else
        echo "[GitWrapper] [DEBUG] No WorkDir specified, using /"
        cd /
    fi

    set -m
    local CMD_ARRAY=()

    # 1. 安全复原 Entrypoint
    if [ -n "$ORIGINAL_ENTRYPOINT" ]; then
        echo "[GitWrapper] [DEBUG] Restoring Entrypoint array from GHA @sh format..."
        # eval 配合我们在 GHA 里生成的 @sh 格式，能完美还原带空格的数组
        eval "EP_ARRAY=($ORIGINAL_ENTRYPOINT)"
        CMD_ARRAY+=("${EP_ARRAY[@]}")
    fi

    # 2. 判断是否覆盖了 CMD
    if [ $# -gt 0 ]; then
        echo "[GitWrapper] [DEBUG] Direct arguments detected ($# args). Overriding original CMD."
        CMD_ARRAY+=("$@")
    elif [ -n "$ORIGINAL_CMD" ]; then
        echo "[GitWrapper] [DEBUG] No direct arguments. Using original CMD from image."
        # 安全复原 CMD
        eval "OCMD_ARRAY=($ORIGINAL_CMD)"
        CMD_ARRAY+=("${OCMD_ARRAY[@]}")
    else
        echo "[GitWrapper] [WARN] No CMD and no arguments provided!"
    fi

    # 安全校验
    if [ ${#CMD_ARRAY[@]} -eq 0 ]; then
        echo "[GitWrapper] [FATAL] Final command array is empty! Cannot start app."
        exit 1
    fi

    echo "[GitWrapper] [DEBUG] --- Final Command Execution Array ---"
    for arg in "${CMD_ARRAY[@]}"; do
        echo "[GitWrapper] [DEBUG] -> '$arg'"
    done
    echo "[GitWrapper] [DEBUG] -------------------------------------"

    # 3. 完美原生地启动应用！
    "${CMD_ARRAY[@]}" 2>&1 &
    APP_PID=$!

    echo "[GitWrapper] [DEBUG] App spawned with PID: $APP_PID"
    sleep 3

    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "[GitWrapper] [FATAL] App died immediately during startup!"
        wait "$APP_PID"
        local exit_code=$?
        echo "[GitWrapper] [FATAL] Exit Code: $exit_code"
        exit $exit_code
    else
        echo "[GitWrapper] [SUCCESS] App is running stably."
    fi

    wait "$APP_PID"
}

# ==================== 5. 主流程 ====================

main() {
    trap 'shutdown_handler' SIGTERM SIGINT

    if init_config; then
        # 如果 restore 失败，内部会直接 exit 1
        restore_data

        (
            set +e
            while true; do
                sleep "$INTERVAL"
                backup_data
            done
        ) &
        SYNC_PID=$!
    else
        echo "[GitWrapper] [WARN] Sync functionality disabled due to configuration error"
    fi

    # 启动应用
    start_main_app "$@"
}

main "$@"
