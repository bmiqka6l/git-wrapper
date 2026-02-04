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

    case "$REPO_URL" in
    http://*) PROTOCOL="http://" ;;
    *) PROTOCOL="https://" ;;
    esac
    CLEAN_URL=$(echo "$REPO_URL" | sed -E "s|^(https?://)||")
    AUTH_URL="${PROTOCOL}${USERNAME}:${PAT}@${CLEAN_URL}"

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

    # 清理目录
    if [ -d "$GIT_STORE" ]; then rm -rf "$GIT_STORE"; fi

    # ---------------------------------------------------------
    # 🚨 修复 1: Clone 失败必须直接退出 (Exit 1)
    # ---------------------------------------------------------
    echo "[GitWrapper] Cloning repository..."
    if ! git clone "$AUTH_URL" "$GIT_STORE" >/dev/null 2>&1; then
        echo "[GitWrapper] [FATAL] Git Clone Failed!"
        echo "[GitWrapper] [FATAL] Please check REPO_URL, USERNAME, PAT (Token) or Network."
        echo "[GitWrapper] [FATAL] Container stopping to prevent data loss."
        exit 1
    fi

    if [ ! -d "$GIT_STORE/.git" ]; then
        echo "[GitWrapper] [FATAL] .git directory missing after clone."
        exit 1
    fi

    cd "$GIT_STORE"

    # 空仓库初始化逻辑
    if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
        echo "[GitWrapper] [WARN] Empty repo. Initializing..."
        git checkout -b "$BRANCH" 2>/dev/null || true
        git commit --allow-empty -m "Init"
        git push -u origin "$BRANCH"
    else
        git checkout "$BRANCH" 2>/dev/null || true
    fi

    # 还原文件逻辑
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
            mkdir -p "$(dirname "$local_path")"
            rm -rf "$local_path"
            cp -r "$REMOTE_PATH" "$local_path"
            # [还原] 脱隐身衣
            if [ -d "$local_path" ]; then
                find "$local_path" -name ".git_backup_cloak" -type d -prune -exec sh -c 'mv "$1" "${1%_backup_cloak}"' _ {} \; 2>/dev/null || true
            fi
        else
            if [ "$path_type" = "dir" ]; then
                echo "[GitWrapper] Creating directory for app: $local_path"
                mkdir -p "$local_path"
            else
                echo "[GitWrapper] Skipping file creation: $local_path"
            fi
        fi
    done
}

backup_data() {
    if [ ! -d "$GIT_STORE/.git" ]; then return; fi

    IFS=';' read -ra MAPPINGS <<<"$SYNC_MAP"
    for MAPPING in "${MAPPINGS[@]}"; do
        # 兼容处理
        if [[ "$MAPPING" == *:* ]]; then
            # 简化逻辑，假设已经是标准化格式或只取后两段
             IFS=':' read -ra PARTS <<<"$MAPPING"
             # 重新处理分割逻辑，确保兼容 restore 的解析方式
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
            cp -r "$local_path" "$REMOTE_FULL"
            # [备份] 穿隐身衣
            if [ -d "$REMOTE_FULL" ]; then
                find "$REMOTE_FULL" -name ".git" -type d -prune -exec mv '{}' '{}_backup_cloak' \; 2>/dev/null || true
            fi
        fi
    done

    cd "$GIT_STORE" || return

    if [ -n "$(git status --porcelain)" ]; then
        echo "[GitWrapper] Syncing changes..."
        git add .
        git commit -m "Backup: $(date '+%Y-%m-%d %H:%M:%S')" >/dev/null
    else
        return
    fi

    # 截断逻辑
    COMMIT_COUNT=$(git rev-list --count HEAD)
    if [ "$HISTORY_LIMIT" -gt 0 ] && [ "$COMMIT_COUNT" -gt "$HISTORY_LIMIT" ]; then
        echo "[GitWrapper] [RESET] Count $COMMIT_COUNT > $HISTORY_LIMIT. Resetting history..."
        CURRENT_BRANCH=$(git branch --show-current)
        git checkout --orphan temp_reset_branch >/dev/null 2>&1
        git add -A
        git commit -m "Reset History: Snapshot at $(date '+%Y-%m-%d %H:%M:%S')" >/dev/null
        git branch -D "$CURRENT_BRANCH" >/dev/null 2>&1
        git branch -m "$CURRENT_BRANCH"
        git push -f origin "$CURRENT_BRANCH" >/dev/null 2>&1 || echo "[GitWrapper] Force push failed"
    else
        git pull --rebase origin "$BRANCH" >/dev/null 2>&1 || true
        git push origin "$BRANCH" >/dev/null 2>&1
    fi
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

# ==================== 4. 显微镜启动 (封装为函数) ====================

# 🚨 修复 2: 将启动逻辑封装在函数中，解决 local 作用域报错
start_main_app() {
    echo "[GitWrapper] >>> Starting App..."
    echo "[GitWrapper] [DEBUG] WorkDir:    '$ORIGINAL_WORKDIR'"
    
    if [ -n "$ORIGINAL_WORKDIR" ]; then
        cd "$ORIGINAL_WORKDIR" || cd /
    else
        cd /
    fi

    local final_args=""
    if [ -n "$*" ]; then
        final_args="$*"
    else
        final_args="$ORIGINAL_CMD"
    fi

    local cmd_str=""
    if [ -n "$ORIGINAL_ENTRYPOINT" ]; then
        cmd_str="$ORIGINAL_ENTRYPOINT $final_args"
    else
        cmd_str="$final_args"
    fi

    if [ -z "$cmd_str" ]; then
        echo "[GitWrapper] [FATAL] No command specified!"
        exit 1
    fi

    echo "[GitWrapper] [DEBUG] Executing: $cmd_str"

    # 智能剥离 Shell 前缀
    local run_cmd="$cmd_str"
    case "$run_cmd" in
    "/bin/sh -c "*)
        run_cmd="${run_cmd#/bin/sh -c }"
        ;;
    "/bin/bash -c "*)
        run_cmd="${run_cmd#/bin/bash -c }"
        ;;
    "sh -c "*)
        run_cmd="${run_cmd#sh -c }"
        ;;
    esac

    # 去除首部空格
    run_cmd=$(echo "$run_cmd" | sed 's/^[[:space:]]*//')

    echo "[GitWrapper] [DEBUG] Cleaned CMD:  $run_cmd"

    set -m
    # 使用 eval 执行
    eval "$run_cmd" 2>&1 &
    APP_PID=$! # 这里赋值全局变量

    echo "[GitWrapper] [DEBUG] PID: $APP_PID"
    sleep 3

    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "[GitWrapper] [FATAL] App died immediately!"
        wait "$APP_PID"
        local exit_code=$?
        echo "[GitWrapper] [FATAL] Exit Code: $exit_code"
        exit $exit_code
    else
        echo "[GitWrapper] [SUCCESS] App is running."
    fi

    wait "$APP_PID"
}

# ==================== 5. 主流程 ====================

main() {
    trap 'shutdown_handler' SIGTERM SIGINT

    if init_config; then
        # 如果 restore 失败，内部会直接 exit 1，不会执行下面的代码
        restore_data

        (
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
