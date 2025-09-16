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

    def on_any_event(self, event):
        if not event.is_directory and time.time() - self.last_event > self.debounce:
            self.last_event = time.time()
            # Kiểm tra có thay đổi không
            result = subprocess.run(['git', 'status', '--porcelain'], capture_output=True, text=True)
            if result.stdout:
                subprocess.run(['git', 'add', '.'])
                subprocess.run(['git', 'commit', '-m', f'Auto update {time.strftime("%Y-%m-%d %H:%M:%S")}'])
                subprocess.run(['git', 'push', '-u', 'origin', 'main'])

def signal_handler(sig, frame):
    print("Stopping script...")
    observer.stop()
    sys.exit(0)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Auto commit and push changes in a specified directory")
    parser.add_argument('path', type=str, help='Path to the directory to monitor')
    args = parser.parse_args()

    monitor_path = os.path.abspath(args.path)
    if not os.path.isdir(monitor_path):
        print(f"Error: {monitor_path} is not a valid directory")
        sys.exit(1)

    os.chdir(monitor_path)
    print(f"Monitoring directory: {monitor_path}")

    if not os.path.exists(os.path.join(monitor_path, '.git')):
        print(f"Error: {monitor_path} is not a Git repository")
        sys.exit(1)


    signal.signal(signal.SIGTERM, signal_handler)

    event_handler = GitHandler()
    observer = Observer()
    observer.schedule(event_handler, path=monitor_path, recursive=True)
    observer.start()
    try:
        while True:
            time.sleep(5)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()