import os
import subprocess
import time
import argparse
import signal
import sys
import logging
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

logging.basicConfig(filename='auto_git.log', level=logging.INFO, format='%(asctime)s: %(message)s')

class GitHandler(FileSystemEventHandler):
    def __init__(self, branch='main', debounce=5):
        self.last_event = 0
        self.debounce = debounce
        self.branch = branch
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

    def handle_unstaged_changes(self):
        result = subprocess.run(['git', 'status', '--porcelain'], capture_output=True, text=True)
        if any(line and not line.startswith('??') for line in result.stdout.splitlines()):
            logging.info("Unstaged changes detected. Committing them...")
            try:
                subprocess.check_call(['git', 'add', '.'])
                subprocess.check_call(['git', 'commit', '-m', 'Auto commit unstaged changes'])
                logging.info("Committed unstaged changes")
            except subprocess.CalledProcessError as e:
                logging.error(f"Error in committing unstaged changes: {e}")
                return False
        return True

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
            if status.startswith('R'):
                old_path, new_path = path.split(' -> ')
                old_name = os.path.basename(old_path)
                new_name = os.path.basename(new_path)
                if os.path.isdir(new_path):
                    deletes_folder.append(old_name)
                    creates_folder.append(new_name)
                else:
                    deletes_file.append(old_name)
                    creates_file.append(new_name)

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
            try:
                subprocess.check_call(['git', 'add', '.'])
                subprocess.check_call(['git', 'commit', '-m', message])
                logging.info(f"Committed: {message}")
            except subprocess.CalledProcessError as e:
                logging.error(f"Error in git add/commit: {e}")
                return

            pull_needed = True
            try:
                subprocess.check_call(['git', 'fetch', 'origin'])
                pull_result = subprocess.run(['git', 'pull', '--rebase', 'origin', self.branch], capture_output=True, text=True)
                if pull_result.returncode != 0:
                    logging.error(f"Pull failed: {pull_result.stderr}")
                    if "You have unstaged changes" in pull_result.stderr:
                        if not self.handle_unstaged_changes():
                            return
                        # Thử pull lại
                        pull_result = subprocess.run(['git', 'pull', '--rebase', 'origin', self.branch], capture_output=True, text=True)
                        if pull_result.returncode != 0:
                            logging.error("Conflict detected during rebase. Aborting rebase.")
                            try:
                                subprocess.check_call(['git', 'rebase', '--abort'])
                            except subprocess.CalledProcessError as e:
                                logging.error(f"Error aborting rebase: {e}")
                            return  # Skip push
                    else:
                        logging.error("Conflict detected during rebase. Aborting rebase.")
                        try:
                            subprocess.check_call(['git', 'rebase', '--abort'])
                        except subprocess.CalledProcessError as e:
                            logging.error(f"Error aborting rebase: {e}")
                        return  # Skip push
                if "Already up to date" in pull_result.stdout:
                    pull_needed = False
                    logging.info("No pull needed (already up to date)")
            except subprocess.CalledProcessError as e:
                logging.error(f"Error in git fetch: {e}")
                return

            # Push nếu pull thành công hoặc không cần pull
            if not pull_needed or pull_result.returncode == 0:
                try:
                    subprocess.check_call(['git', 'push', '-u', 'origin', self.branch])
                    logging.info("Pushed successfully")
                except subprocess.CalledProcessError as e:
                    logging.error(f"Error in git push: {e}")

        # Reset pending lists
        self.pending_creates_file.clear()
        self.pending_creates_folder.clear()
        self.pending_changes_file.clear()
        self.pending_deletes_file.clear()
        self.pending_deletes_folder.clear()

    def on_any_event(self, event):
        self.process_changes()

def signal_handler(sig, frame):
    logging.info("Stopping script...")
    observer.stop()
    sys.exit(0)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Auto commit and push changes in a specified directory")
    parser.add_argument('path', type=str, nargs='?', default=os.path.dirname(os.path.abspath(__file__)),
                        help='Path to the directory to monitor (default: script directory)')
    parser.add_argument('--branch', default='main', help='Git branch to use (default: main)')
    parser.add_argument('--delay', type=int, default=5, help='Delay in seconds (default: 5)')
    args = parser.parse_args()

    monitor_path = os.path.abspath(args.path)
    if not os.path.isdir(monitor_path):
        print(f"Error: {monitor_path} is not a valid directory")
        logging.error(f"Error: {monitor_path} is not a valid directory")
        sys.exit(1)

    if not os.path.exists(os.path.join(monitor_path, '.git')):
        print(f"Error: {monitor_path} is not a Git repository")
        logging.error(f"Error: {monitor_path} is not a Git repository")
        sys.exit(1)

    os.chdir(monitor_path)
    print(f"Monitoring directory: {monitor_path}")
    logging.info(f"Monitoring directory: {monitor_path}")

    signal.signal(signal.SIGTERM, signal_handler)

    event_handler = GitHandler(branch=args.branch, debounce=args.delay)
    observer = Observer()
    observer.schedule(event_handler, path=monitor_path, recursive=True)
    observer.start()
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()