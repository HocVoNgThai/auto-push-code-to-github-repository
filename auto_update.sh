#!/bin/bash
if [ -z "$1" ]; then
    echo "Usage: $0 <path_to_monitor>"
    exit 1
fi

MONITOR_PATH=$(realpath "$1")

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

commit_and_push() {
    if [ -n "$(git status --porcelain)" ]; then
        git add .
        git commit -m "Auto update $(date '+%Y-%m-%d %H:%M:%S')"
        git push origin main
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
        sleep 5
        commit_and_push
    done
fi