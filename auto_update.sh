#!/bin/bash
BRANCH="main"
DELAY=10
MONITOR_PATH=""
LOG_FILE="/tmp/auto_git_$(date +%s).log"

while [[ $# -gt 0 ]]; do
    case $1 in
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --delay)
            DELAY="$2"
            shift 2
            ;;
        *)
            MONITOR_PATH=$(realpath "$1")
            shift
            ;;
    esac
done

if [ -z "$MONITOR_PATH" ]; then
    MONITOR_PATH=$(dirname "$(realpath "$0")")
fi

if [ ! -d "$MONITOR_PATH" ]; then
    echo "Error: $MONITOR_PATH is not a valid directory" | tee -a "$LOG_FILE"
    exit 1
fi

if [ ! -d "$MONITOR_PATH/.git" ]; then
    echo "Error: $MONITOR_PATH is not a Git repository" | tee -a "$LOG_FILE"
    exit 1
fi

cd "$MONITOR_PATH" || exit 1
echo "Monitoring directory: $MONITOR_PATH" | tee -a "$LOG_FILE"

cleanup() {
    echo "$(date): Stopping script..." | tee -a "$LOG_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT

if command -v inotifywait >/dev/null 2>&1; then
    WATCH_TOOL="inotifywait"
elif command -v fswatch >/dev/null 2>&1; then
    WATCH_TOOL="fswatch"
else
    echo "$(date): Error: Please install inotify-tools (Linux) or fswatch (macOS)" | tee -a "$LOG_FILE"
    exit 1
fi

generate_commit_message() {
    local creates_file=""
    local creates_folder=""
    local changes_file=""
    local deletes_file=""
    local deletes_folder=""
    
    while IFS= read -r line; do
        status=$(echo "$line" | awk '{print $1}')
        path=$(echo "$line" | awk '{print $2}')
        name=$(basename "$path")
        if [ -d "$path" ]; then
            if [ "$status" = "A" ]; then
                creates_folder="$creates_folder$name, "
            elif [ "$status" = "D" ]; then
                deletes_folder="$deletes_folder$name, "
            fi
        else
            if [ "$status" = "A" ]; then
                creates_file="$creates_file$name, "
            elif [ "$status" = "M" ]; then
                changes_file="$changes_file$name, "
            elif [ "$status" = "D" ]; then
                deletes_file="$deletes_file$name, "
            fi
        fi
    done < <(git status --porcelain | grep -v 'auto_git.*\.log')
    creates_file=${creates_file%, }
    creates_folder=${creates_folder%, }
    changes_file=${changes_file%, }
    deletes_file=${deletes_file%, }
    deletes_folder=${deletes_folder%, }
    local message=""
    [ -n "$creates_file" ] && message="$message Create file $creates_file;"
    [ -n "$creates_folder" ] && message="$message Create folder $creates_folder;"
    [ -n "$changes_file" ] && message="$message Change file $changes_file;"
    [ -n "$deletes_file" ] && message="$message Delete file $deletes_file;"
    [ -n "$deletes_folder" ] && message="$message Delete folder $deletes_folder;"
    message=${message%;}

    echo "$message"
}

handle_unstaged_changes() {
    if [ -n "$(git status --porcelain | grep -v '^??' | grep -v 'auto_git.*\.log')" ]; then
        echo "$(date): Unstaged changes detected. Committing them..." | tee -a "$LOG_FILE"
        git add .
        if [ $? -ne 0 ]; then
            echo "$(date): Error in git add for unstaged changes" | tee -a "$LOG_FILE"
            return 1
        fi
        git commit -m "Auto commit unstaged changes"
        if [ $? -ne 0 ]; then
            echo "$(date): Error in committing unstaged changes" | tee -a "$LOG_FILE"
            return 1
        fi
        echo "$(date): Committed unstaged changes" | tee -a "$LOG_FILE"
    fi
    return 0
}

check_up_to_date() {
    git fetch origin
    if [ $? -ne 0 ]; then
        echo "$(date): Error in git fetch" | tee -a "$LOG_FILE"
        return 1
    fi
    local status_output=$(git status)
    if echo "$status_output" | grep -q "Your branch is up to date with 'origin/$BRANCH'"; then
        echo "$(date): No pull needed (already up to date)" | tee -a "$LOG_FILE"
        return 0
    fi
    return 1
}

commit_and_push() {
    if [ -n "$(git status --porcelain | grep -v 'auto_git.*\.log')" ]; then
        git add .
        if [ $? -ne 0 ]; then
            echo "$(date): Error in git add" | tee -a "$LOG_FILE"
            return
        fi
        commit_message=$(generate_commit_message)
        if [ -n "$commit_message" ]; then
            git commit -m "$commit_message"
            if [ $? -ne 0 ]; then
                echo "$(date): Error in git commit: $commit_message" | tee -a "$LOG_FILE"
                return
            fi
            echo "$(date): Committed: $commit_message" | tee -a "$LOG_FILE"
        fi
    fi

    if check_up_to_date; then
        git push origin $BRANCH
        if [ $? -ne 0 ]; then
            echo "$(date): Error in git push" | tee -a "$LOG_FILE"
        else
            echo "$(date): Pushed successfully" | tee -a "$LOG_FILE"
        fi
        return
    fi

    handle_unstaged_changes
    if [ $? -ne 0 ]; then
        return
    fi
    pull_output=$(git pull --ff-only origin $BRANCH 2>&1)
    if [ $? -ne 0 ]; then
        echo "$(date): Pull failed (fast-forward): $pull_output" | tee -a "$LOG_FILE"
        pull_output=$(git pull --rebase origin $BRANCH 2>&1)
        if [ $? -ne 0 ]; then
            echo "$(date): Pull failed (rebase): $pull_output" | tee -a "$LOG_FILE"
            echo "$(date): Resolve conflict manually with 'git rebase origin/$BRANCH' or 'git merge origin/$BRANCH'" | tee -a "$LOG_FILE"
            git rebase --abort 2>/dev/null || true
            return 
        fi
    fi

    git push origin $BRANCH
    if [ $? -ne 0 ]; then
        echo "$(date): Error in git push" | tee -a "$LOG_FILE"
    else
        echo "$(date): Pushed successfully" | tee -a "$LOG_FILE"
    fi
}

if [ "$WATCH_TOOL" = "inotifywait" ]; then
    while true; do
        inotifywait -r -e modify,create,delete,move --exclude '(\.git/|\.DS_Store|node_modules/|auto_git.*\.log)' .
        sleep $DELAY
        commit_and_push
    done
elif [ "$WATCH_TOOL" = "fswatch" ]; then
    fswatch -0 -r --exclude '\.git/|\.DS_Store|node_modules/|auto_git.*\.log' . | while read -d "" event; do
        sleep $DELAY 
        commit_and_push
    done
fi