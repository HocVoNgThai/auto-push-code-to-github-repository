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
        self.debounce = 10 
        self.pending_creates_file = set()
        self.pending_creates_folder = set()
        self.pending_changes_file = set()
        self.pending_deletes_file = set()
        self.pending_deletes_folder = set()

    def on_created(self, event):
        if event.is_directory:
            self.pending_creates_folder.add(event.src_path)
        else:
            self.pending_creates_file.add(event.src_path)

    def on_modified(self, event):
        if not event.is_directory:
            self.pending_changes_file.add(event.src_path)

    def on_deleted(self, event):
        if event.is_directory:
            self.pending_deletes_folder.add(event.src_path)
        else:
            self.pending_deletes_file.add(event.src_path)

    def on_moved(self, event):
        if event.is_directory:
            self.pending_deletes_folder.add(event.src_path)
            self.pending_creates_folder.add(event.dest_path)
        else:
            self.pending_deletes_file.add(event.src_path)
            self.pending_creates_file.add(event.dest_path)

    def process_changes(self):
        if time.time() - self.last_event < self.debounce:
            return
        self.last_event = time.time()

        result = subprocess.run(['git', 'status', '--porcelain'], capture_output=True, text=True)
        if not result.stdout:
            return

        creates_file = []
        creates_folder = []
        changes_file = []
        deletes_file = []
        deletes_folder = []
        for line in result.stdout.splitlines():
            status, path = line.split(maxsplit=1)
            path = path.strip()
            name = os.path.basename(path)
            if os.path.isdir(path):
                if status == 'A':
                    creates_folder.append(name)
                elif status == 'D':
                    deletes_folder.append(name)
            else:
                if status == 'A':
                    creates_file.append(name)
                elif status == 'M':
                    changes_file.append(name)
                elif status == 'D':
                    deletes_file.append(name)

        message = ""
        if creates_file:
            message += "Create file " + ", ".join(creates_file) + ";"
        if creates_folder:
            message += "Create folder " + ", ".join(creates_folder) + ";"
        if changes_file:
            message += "Change file " + ", ".join(changes_file) + ";"
        if deletes_file:
            message += "Delete file " + ", ".join(deletes_file) + ";"
        if deletes_folder:
            message += "Delete folder " + ", ".join(deletes_folder) + ";"
        message = message.rstrip(";")

        if message:
            subprocess.run(['git', 'add', '.'])
            subprocess.run(['git', 'commit', '-m', message])
            subprocess.run(['git', 'push', '-u', 'origin', 'main'])

        self.pending_creates_file.clear()
        self.pending_creates_folder.clear()
        self.pending_changes_file.clear()
        self.pending_deletes_file.clear()
        self.pending_deletes_folder.clear()

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