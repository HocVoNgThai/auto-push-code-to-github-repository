#!/bin/bash

if [ -z "$1" ]; then
    MONITOR_PATH=$(dirname "$(realpath "$0")")
else
    MONITOR_PATH=$(realpath "$1")
fi

if [ ! -d "$MONITOR_PATH" ]; then
    echo "Error: $MONITOR_PATH is not a valid directory"
    exit 1
fi

if [ ! -d "$MONITOR_PATH/.git" ]; then
    echo "Error: $MONITOR_PATH is not a Git repository"
    exit 1
fi

cd "$MONITOR_PATH" || exit 1
echo "Monitoring directory: $MONITOR_PATH"

cleanup() {
    echo "Stopping script..."
    exit 0
}

trap cleanup SIGTERM SIGINT

if command -v inotifywait >/dev/null 2>&1; then
    WATCH_TOOL="inotifywait"
elif command -v fswatch >/dev/null 2>&1; then
    WATCH_TOOL="fswatch"
else
    echo "Error: Please install inotify-tools (Linux) or fswatch (macOS)"
    exit 1
fi

generate_commit_message() {
    local changes=""
    local deletes=""
    
    while IFS= read -r line; do
        status=$(echo "$line" | awk '{print $1}')
        file=$(echo "$line" | awk '{print $2}')
        if [ "$status" = "M" ] || [ "$status" = "A" ]; then
            changes="$changes$file, "
        elif [ "$status" = "D" ]; then
            deletes="$deletes$file, "
        fi
    done < <(git status --porcelain)

    changes=${changes%, }
    deletes=${deletes%, }

    local message=""
    if [ -n "$changes" ]; then
        message="Change $changes"
    fi
    if [ -n "$deletes" ]; then
        if [ -n "$message" ]; then
            message="$message; Delete $deletes"
        else
            message="Delete $deletes"
        fi
    fi
    echo "$message"
}

commit_and_push() {
    if [ -n "$(git status --porcelain)" ]; then
        git add .
        commit_message=$(generate_commit_message)
        if [ -n "$commit_message" ]; then
            git commit -m "$commit_message"
            git push -u origin main
        fi
    fi
}

if [ "$WATCH_TOOL" = "inotifywait" ]; then
    while true; do
        inotifywait -r -e modify,create,delete,move --exclude '(\.git/|\.DS_Store|node_modules/)' .
        sleep 5  
        commit_and_push
    done
elif [ "$WATCH_TOOL" = "fswatch" ]; then
    fswatch -0 -r --exclude '\.git/|\.DS_Store|node_modules/' . | while read -d "" event; do
        sleep 10 
        commit_and_push
    done
fi