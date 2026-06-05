#!/bin/bash
set -e

# ==================== 0. 环境变量 ====================
REPO_URL="$GW_REPO_URL"
USERNAME="${GW_USER:-git}"
PAT="$GW_PAT"
BRANCH="${GW_BRANCH:-main}"
INTERVAL="${GW_INTERVAL:-300}"
SYNC_MAP="$GW_SYNC_MAP"
IGNORE_RULES="${GW_IGNORE:-*.log}" # 忽略规则

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
    
    # 2. PAT URL 编码
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
    # 阶段 1: Clone 到临时目录
    # ========================================================
    local TEMP_CLONE_DIR="/tmp/git-clone-temp-$(date +%s)-$RANDOM"
    echo "[GitWrapper] Cloning to temporary location..."

    if ! git clone "$AUTH_URL" "$TEMP_CLONE_DIR"; then
        echo "[GitWrapper] [FATAL] Git Clone Failed!"
        echo "[GitWrapper] [FATAL] Please check Network or Token validity."
        rm -rf "$TEMP_CLONE_DIR"
        exit 1
    fi

    if [ ! -d "$GIT_STORE" ]; then
        mkdir -p "$GIT_STORE"
    else
        echo "[GitWrapper] Cleaning existing GIT_STORE..."
        shopt -s dotglob 2>/dev/null || true
        rm -rf "$GIT_STORE"/*
        shopt -u dotglob 2>/dev/null || true
    fi

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

    # ========================================================
    # 🚨 修复 1: 先确保切到正确的环境与分支，再写入工作区文件
    # ========================================================
    local INIT_REPO=false
    if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
        echo "[GitWrapper] [WARN] Empty repo. Initializing branch..."
        git checkout -b "$BRANCH" 2>/dev/null || {
            echo "[GitWrapper] [FATAL] Failed to create branch: $BRANCH"
            exit 1
        }
        INIT_REPO=true
    else
        git checkout "$BRANCH" 2>/dev/null || {
            echo "[GitWrapper] [FATAL] Failed to checkout branch: $BRANCH"
            exit 1
        }
    fi

    # 阶段 1.5: 写入 .gitignore 规则
    echo "[GitWrapper] [DEBUG] Applying .gitignore rules: $IGNORE_RULES"
    : > .gitignore # 清空或创建
    IFS=';' read -ra IGNS <<< "$IGNORE_RULES"
    for ign in "${IGNS[@]}"; do
        ign="$(echo "$ign" | xargs)"
        [ -n "$ign" ] && echo "$ign" >> .gitignore
    done

    # 只有第一次空仓库时才立马推上去，已有仓库的 .gitignore 变化交给 backup_data 处理
    if [ "$INIT_REPO" = true ]; then
        git add .gitignore
        git commit -m "Init with .gitignore"
        git push -u origin "$BRANCH" || true
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
            
            if [ ! -d "$(dirname "$local_path")" ]; then
                mkdir -p "$(dirname "$local_path")"
            fi

            if [ -d "$local_path" ]; then
                echo "[GitWrapper] [DEBUG] Target is directory/volume, cleaning contents..."
                shopt -s dotglob 2>/dev/null || true
                rm -rf "$local_path"/*
                if [ -d "$REMOTE_PATH" ]; then
                     cp -r "$REMOTE_PATH"/* "$local_path"/
                else
                     cp -r "$REMOTE_PATH" "$local_path"/
                fi
                shopt -u dotglob 2>/dev/null || true
            else
                rm -rf "$local_path"
                cp -r "$REMOTE_PATH" "$local_path"
            fi

            if [ -d "$local_path" ]; then
                find "$local_path" -name ".git_backup_cloak" -type d -prune -exec sh -c 'mv "$1" "${1%_backup_cloak}"' _ {} \; 2>/dev/null || true
            fi
        else
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
        return 1
    fi

    if [ -d "$GIT_STORE/.git/rebase-merge" ] || [ -d "$GIT_STORE/.git/rebase-apply" ]; then
        echo "[GitWrapper] [WARN] Stale rebase state detected. Smashing the lock..."
        git rebase --abort >/dev/null 2>&1 || rm -rf "$GIT_STORE/.git/rebase-merge" "$GIT_STORE/.git/rebase-apply"
        git checkout -f "$BRANCH" >/dev/null 2>&1 || true
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
            
            if [ -d "$REMOTE_FULL" ]; then
                find "$REMOTE_FULL" -name ".git" -type d -prune -exec mv '{}' '{}_backup_cloak' \; 2>/dev/null || true
            fi
        else
            echo "[GitWrapper] [WARN] Local path not found, skipping copy: $local_path"
        fi
    done

    cd "$GIT_STORE" || { echo "[GitWrapper] [ERROR] Failed to enter $GIT_STORE"; return 1; }

    echo "[GitWrapper] [DEBUG] Checking Git status..."
    local GIT_STATUS
    GIT_STATUS=$(git status --porcelain)

    if [ -n "$GIT_STATUS" ]; then
        echo "[GitWrapper] [INFO] Changes detected:"
        echo "$GIT_STATUS" | while read -r line; do
            echo "[GitWrapper] [DEBUG]   -> $line"
        done

        echo "[GitWrapper] [DEBUG] Adding changes to index..."
        git add .

        echo "[GitWrapper] [DEBUG] Committing..."
        # 🚨 修复 2: commit 失败时返回 1，真实体现失败状态
        if git commit -m "Backup: $(date '+%Y-%m-%d %H:%M:%S')"; then
            echo "[GitWrapper] [INFO] Commit successful."
        else
            echo "[GitWrapper] [ERROR] Commit failed!"
            return 1
        fi
    else
        echo "[GitWrapper] [INFO] No changes detected. Skipping commit and push."
        echo "[GitWrapper] [DEBUG] ========================================"
        return 0
    fi

    COMMIT_COUNT=$(git rev-list --count HEAD 2>/dev/null || echo 0)
    echo "[GitWrapper] [DEBUG] Current commit count: $COMMIT_COUNT / Limit: $HISTORY_LIMIT"

    normal_push() {
        echo "[GitWrapper] [DEBUG] Pulling latest from origin (rebase)..."
        if ! git pull --rebase origin "$BRANCH"; then
            echo "[GitWrapper] [WARN] Git pull failed or encountered conflicts!"
            echo "[GitWrapper] [DEBUG] Aborting rebase to prevent directory lock..."
            git rebase --abort >/dev/null 2>&1 || true
            return 1
        fi

        echo "[GitWrapper] [DEBUG] Pushing to origin..."
        if git push origin "$BRANCH"; then
            echo "[GitWrapper] [INFO] Push successful."
            return 0
        else
            echo "[GitWrapper] [ERROR] Push failed! Check permissions or network."
            return 1
        fi
    }

    truncate_history() {
        local original_ref
        original_ref="$(git rev-parse HEAD)" || return 1

        echo "[GitWrapper] [INFO] History limit reached. Try truncation."

        if ! git checkout --orphan temp_reset_branch >/dev/null 2>&1; then
            echo "[GitWrapper] [WARN] Failed to create orphan branch. Fallback to normal push."
            git checkout -f "$BRANCH" >/dev/null 2>&1 || true
            return 1
        fi

        git add -A
        if ! git commit -m "Reset History: Snapshot at $(date '+%Y-%m-%d %H:%M:%S')"; then
            echo "[GitWrapper] [WARN] Failed to create reset commit. Fallback to normal push."
            git checkout -f "$BRANCH" >/dev/null 2>&1 || true
            return 1
        fi

        git branch -D "$BRANCH" >/dev/null 2>&1 || true
        
        # 🚨 修复 3: 重命名失败时恢复原提交，防止游离或错乱
        git branch -m "$BRANCH" || {
            echo "[GitWrapper] [WARN] Failed to rename reset branch. Fallback to normal push."
            git checkout -B "$BRANCH" "$original_ref" >/dev/null 2>&1 || return 1
            return 1
        }

        echo "[GitWrapper] [DEBUG] Force pushing to origin..."
        if git push -f origin "$BRANCH"; then
            echo "[GitWrapper] [INFO] History truncation completed successfully."
            return 0
        fi

        echo "[GitWrapper] [WARN] Force push failed! (Check protected branch settings). Fallback to normal push."
        echo "[GitWrapper] [INFO] Rolling back to original backup commit..."

        if ! git checkout -B "$BRANCH" "$original_ref" >/dev/null 2>&1; then
            echo "[GitWrapper] [ERROR] Failed to restore original commit after truncation failure."
            return 1
        fi

        return 1
    }

    # 决策树
    if [ "$HISTORY_LIMIT" -gt 0 ] && [ "$COMMIT_COUNT" -gt "$HISTORY_LIMIT" ]; then
        truncate_history || normal_push
    else
        normal_push
    fi
    
    local final_status=$?
    echo "[GitWrapper] [DEBUG] Backup cycle finished."
    echo "[GitWrapper] [DEBUG] ========================================"
    return $final_status
}

shutdown_handler() {
    echo "[GitWrapper] !!! Shutting down..."
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill -SIGTERM "$APP_PID"
        wait "$APP_PID"
    fi
    if [ -n "$SYNC_PID" ]; then
        kill -SIGTERM "$SYNC_PID" 2>/dev/null
        backup_data
    fi
    exit 0
}

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

    if [ -n "$ORIGINAL_ENTRYPOINT" ]; then
        echo "[GitWrapper] [DEBUG] Restoring Entrypoint array from GHA @sh format..."
        eval "EP_ARRAY=($ORIGINAL_ENTRYPOINT)"
        CMD_ARRAY+=("${EP_ARRAY[@]}")
    fi

    if [ $# -gt 0 ]; then
        echo "[GitWrapper] [DEBUG] Direct arguments detected ($# args). Overriding original CMD."
        CMD_ARRAY+=("$@")
    elif [ -n "$ORIGINAL_CMD" ]; then
        echo "[GitWrapper] [DEBUG] No direct arguments. Using original CMD from image."
        eval "OCMD_ARRAY=($ORIGINAL_CMD)"
        CMD_ARRAY+=("${OCMD_ARRAY[@]}")
    else
        echo "[GitWrapper] [WARN] No CMD and no arguments provided!"
    fi

    if [ ${#CMD_ARRAY[@]} -eq 0 ]; then
        echo "[GitWrapper] [FATAL] Final command array is empty! Cannot start app."
        exit 1
    fi

    echo "[GitWrapper] [DEBUG] --- Final Command Execution Array ---"
    for arg in "${CMD_ARRAY[@]}"; do
        echo "[GitWrapper] [DEBUG] -> '$arg'"
    done
    echo "[GitWrapper] [DEBUG] -------------------------------------"

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
        restore_data

        (
            set +e
            while true; do
                sleep "$INTERVAL"
                backup_data || echo "[GitWrapper] [WARN] Backup cycle reported an error."
            done
        ) &
        SYNC_PID=$!
    else
        echo "[GitWrapper] [WARN] Sync functionality disabled due to configuration error"
    fi

    start_main_app "$@"
}

main "$@"
