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
    done < <(git status --porcelain)

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
        sleep 5 
        commit_and_push
    done
fi