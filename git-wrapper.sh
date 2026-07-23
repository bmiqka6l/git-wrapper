#!/bin/bash
set -e

# ==================== 0. 环境变量配置 ====================
REPO_URL="$GW_REPO_URL"
USERNAME="${GW_USER:-git}"
PAT="$GW_PAT"
BRANCH="${GW_BRANCH:-main}"
INTERVAL="${GW_INTERVAL:-300}"
SYNC_MAP="$GW_SYNC_MAP"
IGNORE_RULES="${GW_IGNORE:-*.log}" 

# 历史截断配置
HISTORY_LIMIT="${GW_HISTORY_LIMIT:-50}"

# 继承的原镜像参数
ORIGINAL_ENTRYPOINT="$GW_ORIGINAL_ENTRYPOINT"
ORIGINAL_CMD="$GW_ORIGINAL_CMD"
ORIGINAL_WORKDIR="$GW_ORIGINAL_WORKDIR"

GIT_STORE="/git-store"
APP_PID=""
SYNC_PID=""

# ==================== 1. 初始化校验 ====================
init_config() {
    if [ -z "$REPO_URL" ] || [ -z "$PAT" ] || [ -z "$SYNC_MAP" ]; then
        echo "[GitWrapper] [ERROR] Missing required variables: GW_REPO_URL, GW_PAT, GW_SYNC_MAP"
        return 1
    fi

    case "$REPO_URL" in
    http://*) PROTOCOL="http://" ;;
    *) PROTOCOL="https://" ;;
    esac
    CLEAN_URL=$(echo "$REPO_URL" | sed -E "s|^(https?://)||")
    
    local ENCODED_PAT=$(echo "$PAT" | sed 's/%/%25/g' | sed 's/@/%40/g' | sed 's/:/%3A/g' | sed 's|/|%2F|g' | sed 's/+/%2B/g')
    local ENCODED_USER=$(echo "$USERNAME" | sed 's/%/%25/g' | sed 's/@/%40/g' | sed 's/:/%3A/g' | sed 's|/|%2F|g' | sed 's/+/%2B/g')

    AUTH_URL="${PROTOCOL}${ENCODED_USER}:${ENCODED_PAT}@${CLEAN_URL}"
    return 0
}

# ==================== 2. 数据恢复流程 ====================
restore_data() {
    echo "[GitWrapper] [INFO] Initializing & Restoring data..."
    
    git config --global --add safe.directory "$GIT_STORE"
    git config --global user.name "${USERNAME:-BackupBot}"
    git config --global user.email "${USERNAME:-bot}@wrapper.local"
    git config --global init.defaultBranch "$BRANCH"

    local TEMP_CLONE_DIR="/tmp/git-clone-temp-$(date +%s)-$RANDOM"

    if ! git clone "$AUTH_URL" "$TEMP_CLONE_DIR" >/dev/null 2>&1; then
        echo "[GitWrapper] [FATAL] Git clone failed. Check network or credentials."
        rm -rf "$TEMP_CLONE_DIR"
        exit 1
    fi

    if [ ! -d "$GIT_STORE" ]; then
        mkdir -p "$GIT_STORE"
    else
        shopt -s dotglob 2>/dev/null || true
        rm -rf "$GIT_STORE"/*
        shopt -u dotglob 2>/dev/null || true
    fi

    shopt -s dotglob 2>/dev/null || true
    if ! mv "$TEMP_CLONE_DIR"/* "$GIT_STORE/"; then
        echo "[GitWrapper] [FATAL] Failed to move repository to $GIT_STORE"
        rm -rf "$TEMP_CLONE_DIR"
        exit 1
    fi
    shopt -u dotglob 2>/dev/null || true
    rm -rf "$TEMP_CLONE_DIR"

    if [ ! -d "$GIT_STORE/.git" ]; then
        echo "[GitWrapper] [FATAL] .git directory missing."
        exit 1
    fi

    cd "$GIT_STORE"

    # 分支初始化与校验
    local INIT_REPO=false
    if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
        echo "[GitWrapper] [INFO] Empty repository. Initializing branch $BRANCH."
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

    # 写入并提交 .gitignore
    : > .gitignore
    IFS=';' read -ra IGNS <<< "$IGNORE_RULES"
    for ign in "${IGNS[@]}"; do
        ign="$(echo "$ign" | xargs)"
        [ -n "$ign" ] && echo "$ign" >> .gitignore
    done

    if [ "$INIT_REPO" = true ]; then
        git add .gitignore
        git commit -m "Init with .gitignore" >/dev/null 2>&1 || true
        git push -u origin "$BRANCH" >/dev/null 2>&1 || true
    fi

    # 同步映射处理
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
            continue
        fi

        REMOTE_PATH="$GIT_STORE/$remote_rel"

        if [ -e "$REMOTE_PATH" ]; then
            if [ ! -d "$(dirname "$local_path")" ]; then
                mkdir -p "$(dirname "$local_path")"
            fi

            if [ -d "$local_path" ]; then
                shopt -s dotglob 2>/dev/null || true
                rm -rf "$local_path"/*
                if [ -d "$REMOTE_PATH" ]; then
                     cp -r "$REMOTE_PATH"/* "$local_path"/
                else
                     cp -r "$REMOTE_PATH" "$local_path"/
                fi
                shopt -u dotglob 2>/dev/null || true

                chmod -R 777 "$local_path" 2>/dev/null || true
            else
                rm -rf "$local_path"
                cp -r "$REMOTE_PATH" "$local_path"

                chmod 777 "$local_path" 2>/dev/null || true
                chmod 777 "$(dirname "$local_path")" 2>/dev/null || true
            fi

            if [ -d "$local_path" ]; then
                find "$local_path" -name ".git_backup_cloak" -type d -prune -exec sh -c 'mv "$1" "${1%_backup_cloak}"' _ {} \; 2>/dev/null || true
            fi
        else
            if [ "$path_type" = "dir" ]; then
                if [ ! -d "$local_path" ]; then
                    mkdir -p "$local_path"
                fi
            fi
        fi
    done
}

# ==================== 3. 周期备份流程 ====================
backup_data() {
    if [ ! -d "$GIT_STORE/.git" ]; then 
        return 1
    fi

    # 清除残留的 rebase 锁并退出游离态
    if [ -d "$GIT_STORE/.git/rebase-merge" ] || [ -d "$GIT_STORE/.git/rebase-apply" ]; then
        git rebase --abort >/dev/null 2>&1 || rm -rf "$GIT_STORE/.git/rebase-merge" "$GIT_STORE/.git/rebase-apply"
        git checkout -f "$BRANCH" >/dev/null 2>&1 || true
    fi

    # 映射文件至暂存区
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
            mkdir -p "$(dirname "$REMOTE_FULL")"
            rm -rf "$REMOTE_FULL"
            
            cp -r "$local_path" "$REMOTE_FULL" 2>/dev/null || true
            
            if [ -d "$REMOTE_FULL" ]; then
                find "$REMOTE_FULL" -name ".git" -type d -prune -exec mv '{}' '{}_backup_cloak' \; 2>/dev/null || true
            fi
        fi
    done

    cd "$GIT_STORE" || return 1

    # 状态检查与提交
    local GIT_STATUS
    GIT_STATUS=$(git status --porcelain)

    if [ -n "$GIT_STATUS" ]; then
        git add .
        if ! git commit -m "Backup: $(date '+%Y-%m-%d %H:%M:%S')" >/dev/null 2>&1; then
            echo "[GitWrapper] [ERROR] Commit failed."
            return 1
        fi
    else
        # 验证是否存在遗留的未推送 Commit
        local AHEAD_COUNT=0
        if git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1; then
            AHEAD_COUNT=$(git rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo 0)
        else
            AHEAD_COUNT=-1
        fi

        if [ "$AHEAD_COUNT" -eq 0 ]; then
            return 0
        fi
    fi

    COMMIT_COUNT=$(git rev-list --count HEAD 2>/dev/null || echo 0)

    # 推送策略：普通推送
    normal_push() {
        if ! git pull --rebase origin "$BRANCH" >/dev/null 2>&1; then
            git rebase --abort >/dev/null 2>&1 || true
            return 1
        fi

        if git push origin "$BRANCH" >/dev/null 2>&1; then
            return 0
        else
            return 1
        fi
    }

    # 推送策略：历史截断
    truncate_history() {
        local original_ref
        original_ref="$(git rev-parse HEAD)" || return 1

        if ! git checkout --orphan temp_reset_branch >/dev/null 2>&1; then
            git checkout -f "$BRANCH" >/dev/null 2>&1 || true
            return 1
        fi

        git add -A
        if ! git commit -m "Reset History: Snapshot at $(date '+%Y-%m-%d %H:%M:%S')" >/dev/null 2>&1; then
            git checkout -f "$BRANCH" >/dev/null 2>&1 || true
            return 1
        fi

        git branch -D "$BRANCH" >/dev/null 2>&1 || true
        
        if ! git branch -m "$BRANCH" >/dev/null 2>&1; then
            git checkout -B "$BRANCH" "$original_ref" >/dev/null 2>&1 || return 1
            return 1
        fi

        if git push -f origin "$BRANCH" >/dev/null 2>&1; then
            echo "[GitWrapper] [INFO] History truncated successfully."
            return 0
        fi

        # 截断失败回滚
        if ! git checkout -B "$BRANCH" "$original_ref" >/dev/null 2>&1; then
            return 1
        fi
        return 1
    }

    # 执行推送策略
    if [ "$HISTORY_LIMIT" -gt 0 ] && [ "$COMMIT_COUNT" -gt "$HISTORY_LIMIT" ]; then
        truncate_history || normal_push
    else
        normal_push
    fi
    
    return $?
}

# ==================== 4. 生命周期管理 ====================
shutdown_handler() {
    echo "[GitWrapper] [INFO] Shutting down container..."
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill -SIGTERM "$APP_PID"
        wait "$APP_PID"
    fi
    if [ -n "$SYNC_PID" ]; then
        kill -SIGTERM "$SYNC_PID" 2>/dev/null
        backup_data || true
    fi
    exit 0
}

start_main_app() {
    if [ -n "$ORIGINAL_WORKDIR" ]; then
        cd "$ORIGINAL_WORKDIR" || cd /
    else
        cd /
    fi

    set -m
    local CMD_ARRAY=()

    if [ -n "$ORIGINAL_ENTRYPOINT" ]; then
        eval "EP_ARRAY=($ORIGINAL_ENTRYPOINT)"
        CMD_ARRAY+=("${EP_ARRAY[@]}")
    fi

    if [ $# -gt 0 ]; then
        CMD_ARRAY+=("$@")
    elif [ -n "$ORIGINAL_CMD" ]; then
        eval "OCMD_ARRAY=($ORIGINAL_CMD)"
        CMD_ARRAY+=("${OCMD_ARRAY[@]}")
    fi

    if [ ${#CMD_ARRAY[@]} -eq 0 ]; then
        echo "[GitWrapper] [FATAL] Command array is empty. Exiting."
        exit 1
    fi

    "${CMD_ARRAY[@]}" 2>&1 &
    APP_PID=$!

    sleep 3

    if ! kill -0 "$APP_PID" 2>/dev/null; then
        wait "$APP_PID"
        local exit_code=$?
        echo "[GitWrapper] [FATAL] Application failed to start. Exit code: $exit_code"
        exit $exit_code
    fi

    wait "$APP_PID"
}

# ==================== 5. 入口执行 ====================
main() {
    trap 'shutdown_handler' SIGTERM SIGINT

    if init_config; then
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
        echo "[GitWrapper] [WARN] Sync function disabled due to configuration errors."
    fi

    start_main_app "$@"
}

main "$@"
