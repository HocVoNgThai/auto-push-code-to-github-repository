import os
import subprocess
import time
import argparse
import signal
import sys
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

class GitHandler(FileSystemEventHandler):
    def __init__(self):
        self.last_event = 0
        self.debounce = 5 
        self.pending_changes = set()
        self.pending_deletes = set()

    def on_created(self, event):
        if not event.is_directory:
            self.pending_changes.add(event.src_path)

    def on_modified(self, event):
        if not event.is_directory:
            self.pending_changes.add(event.src_path)

    def on_deleted(self, event):
        if not event.is_directory:
            self.pending_deletes.add(event.src_path)

    def on_moved(self, event):
        if not event.is_directory:
            self.pending_deletes.add(event.src_path)
            self.pending_changes.add(event.dest_path)

    def process_changes(self):
        if time.time() - self.last_event < self.debounce:
            return
        self.last_event = time.time()

        result = subprocess.run(['git', 'status', '--porcelain'], capture_output=True, text=True)
        if not result.stdout:
            return

        changes = []
        deletes = []
        for line in result.stdout.splitlines():
            status, file = line.split(maxsplit=1)
            file = file.strip()
            if status in ('M', 'A'):
                changes.append(os.path.basename(file))
            elif status == 'D':
                deletes.append(os.path.basename(file))

        message = ""
        if changes:
            message += "Change " + ", ".join(changes)
        if deletes:
            if message:
                message += "; Delete " + ", ".join(deletes)
            else:
                message = "Delete " + ", ".join(deletes)

        if message:
            subprocess.run(['git', 'add', '.'])
            subprocess.run(['git', 'commit', '-m', message])
            subprocess.run(['git', 'push', '-u','origin', 'main'])

        self.pending_changes.clear()
        self.pending_deletes.clear()

    def on_any_event(self, event):
        self.process_changes()

def signal_handler(sig, frame):
    print("Stopping script...")
    observer.stop()
    sys.exit(0)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Auto commit and push changes in a specified directory")
    parser.add_argument('path', type=str, nargs='?', default=os.path.dirname(os.path.abspath(__file__)),
                        help='Path to the directory to monitor (default: script directory)')
    args = parser.parse_args()

    monitor_path = os.path.abspath(args.path)
    if not os.path.isdir(monitor_path):
        print(f"Error: {monitor_path} is not a valid directory")
        sys.exit(1)

    if not os.path.exists(os.path.join(monitor_path, '.git')):
        print(f"Error: {monitor_path} is not a Git repository")
        sys.exit(1)

    os.chdir(monitor_path)
    print(f"Monitoring directory: {monitor_path}")

    signal.signal(signal.SIGTERM, signal_handler)

    event_handler = GitHandler()
    observer = Observer()
    observer.schedule(event_handler, path=monitor_path, recursive=True)
    observer.start()
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()