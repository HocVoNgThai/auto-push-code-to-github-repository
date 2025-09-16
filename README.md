<div align = "center">
  
  # auto-push-code-to-github-repository ⚙️

</div>

## Introduction 📃
This repository provides scripts to automatically update your source code to GitHub. It includes three scripts in Python, Bash, and PowerShell for Linux, macOS, and Windows, along with a .gitignore file that lists file types to be excluded when pushing code, helping to minimize unnecessary commits.

---
## Credential 🔑
To use the script, you need to make sure that when pushing code to the GitHub repository, no authentication requirement appears and the authentication is handled automatically. There are two ways to do that 👇.

---
### Using HTTPS + Personal Access Token (PAT)
- First, you have to generate access token. Follow this: `GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate token → Generate token (classic) → Tick all the checkboxs → Choose "No expiration" for Expiration, generate and save token`.
- In the terminal. Run this command:
  - Linux:
```
git config --global credential.helper store
```
  - MacOS:
```
git config --global credential.helper osxkeychain
```
- Now when you push code for the first time, username and access token will be required. After the first authentication, the credential information will be saved.
- To see the credential storage file or remove use these commands:
```
nano ~/.git-credentials
rm ~/.git-credentials
```
### Using SSH Key
- Create your SSH key:
```
ssh-keygen -t ed25519 -C "youremail@example.com"
```
- Start SSH agent and add key:
```
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```
- Copy public key:
```
cat ~/.ssh/id_ed25519.pub
```
- Open GitHub → Settings → SSH and GPG keys → New SSH key → Paste public key.
-  Change remote to SSH mode:
```
git remote set-url origin git@github.com:USERNAME/REPO.git
```

---
## How to use ❓
- Get inotify-tools:
  - Linux:
```
sudo apt install inotify-tools
```
  - MacOS:
```
brew install inotify-tools
```
- Get source code:


