import os
import subprocess
import time
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

class GitHandler(FileSystemEventHandler):
    def __init__(self):
        self.last_event = 0
        self.debounce = 10

    def on_any_event(self, event):
        if not event.is_directory and time.time() - self.last_event > self.debounce:
            self.last_event = time.time()
            if subprocess.run(['git', 'status', '--porcelain']).stdout:
                subprocess.run(['git', 'add', '.'])
                subprocess.run(['git', 'commit', '-m', f'Auto update {time.strftime("%Y-%m-%d %H:%M:%S")}'])
                subprocess.run(['git', 'push', 'u','origin', 'main'])

if __name__ == "__main__":
    event_handler = GitHandler()
    observer = Observer()
    observer.schedule(event_handler, path='.', recursive=True)
    observer.start()
    try:
        while True:
            time.sleep(20)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()