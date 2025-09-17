$ErrorActionPreference = "Stop"

# Xử lý arguments
param (
    [string]$Path = (Split-Path -Parent $MyInvocation.MyCommand.Path),
    [string]$Branch = "main",
    [int]$Delay = 5
)

# Chuyển đổi sang đường dẫn tuyệt đối
$MonitorPath = (Resolve-Path $Path -ErrorAction Stop).Path

# Kiểm tra xem đường dẫn có tồn tại và là thư mục không
if (-not (Test-Path $MonitorPath -PathType Container)) {
    Write-Error "$MonitorPath is not a valid directory"
    exit 1
}

# Kiểm tra xem thư mục có phải là Git repository không
if (-not (Test-Path (Join-Path $MonitorPath ".git") -PathType Container)) {
    Write-Error "$MonitorPath is not a Git repository"
    exit 1
}

# Chuyển thư mục làm việc
Set-Location $MonitorPath
Write-Host "Monitoring directory: $MonitorPath"
Add-Content -Path "auto_git.log" -Value "$(Get-Date): Monitoring directory: $MonitorPath"

# Hàm xử lý tín hiệu dừng (Ctrl+C)
$Global:Running = $true
$SIGINTHandler = {
    Add-Content -Path "auto_git.log" -Value "$(Get-Date): Stopping script..."
    $Global:Running = $false
}
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action $SIGINTHandler

# Tạo FileSystemWatcher
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $MonitorPath
$watcher.IncludeSubdirectories = $true
$watcher.EnableRaisingEvents = $true
$watcher.Filter = "*.*"
$watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::DirectoryName -bor [System.IO.NotifyFilters]::LastWrite

# Biến lưu trữ thay đổi
$lastEventTime = Get-Date
$debounceSeconds = $Delay
$pendingCreatesFile = @{}
$pendingCreatesFolder = @{}
$pendingChangesFile = @{}
$pendingDeletesFile = @{}
$pendingDeletesFolder = @{}

function Generate-CommitMessage {
    $createsFile = @()
    $createsFolder = @()
    $changesFile = @()
    $deletesFile = @()
    $deletesFolder = @()

    $gitStatus = git status --porcelain
    if ($gitStatus) {
        foreach ($line in $gitStatus) {
            $status, $path = $line -split '\s+',2
            $path = $path.Trim()
            $name = [System.IO.Path]::GetFileName($path)
            if (Test-Path $path -PathType Container) {
                if ($status -eq 'A') {
                    $createsFolder += $name
                } elseif ($status -eq 'D') {
                    $deletesFolder += $name
                }
            } else {
                if ($status -eq 'A') {
                    $createsFile += $name
                } elseif ($status -eq 'M') {
                    $changesFile += $name
                } elseif ($status -eq 'D') {
                    $deletesFile += $name
                }
            }
            if ($status -match '^R') {
                $oldPath, $newPath = $path -split ' -> '
                $oldName = [System.IO.Path]::GetFileName($oldPath)
                $newName = [System.IO.Path]::GetFileName($newPath)
                if (Test-Path $newPath -PathType Container) {
                    $deletesFolder += $oldName
                    $createsFolder += $newName
                } else {
                    $deletesFile += $oldName
                    $createsFile += $newName
                }
            }
        }
    }

    $message = ""
    if ($createsFile) {
        $message += "Create file $($createsFile -join ', ');"
    }
    if ($createsFolder) {
        $message += "Create folder $($createsFolder -join ', ');"
    }
    if ($changesFile) {
        $message += "Change file $($changesFile -join ', ');"
    }
    if ($deletesFile) {
        $message += "Delete file $($deletesFile -join ', ');"
    }
    if ($deletesFolder) {
        $message += "Delete folder $($deletesFolder -join ', ');"
    }
    $message = $message.TrimEnd(';')
    return $message
}

function Commit-AndPush {
    if ((Get-Date) - $script:lastEventTime -lt [TimeSpan]::FromSeconds($debounceSeconds)) {
        return
    }
    $script:lastEventTime = Get-Date

    $gitStatus = git status --porcelain
    if ($gitStatus) {
        git add .
        if ($LASTEXITCODE -ne 0) {
            Add-Content -Path "auto_git.log" -Value "$(Get-Date): Error in git add"
            return
        }
        $commitMessage = Generate-CommitMessage
        if ($commitMessage) {
            git commit -m $commitMessage
            if ($LASTEXITCODE -ne 0) {
                Add-Content -Path "auto_git.log" -Value "$(Get-Date): Error in git commit: $commitMessage"
                return
            }
            Add-Content -Path "auto_git.log" -Value "$(Get-Date): Committed: $commitMessage"
        }
    }

    git fetch origin
    if ($LASTEXITCODE -ne 0) {
        Add-Content -Path "auto_git.log" -Value "$(Get-Date): Error in git fetch"
        return
    }
    git pull --rebase origin $Branch
    if ($LASTEXITCODE -ne 0) {
        Add-Content -Path "auto_git.log" -Value "$(Get-Date): Conflict detected during rebase. Aborting rebase."
        git rebase --abort
        if ($LASTEXITCODE -ne 0) {
            Add-Content -Path "auto_git.log" -Value "$(Get-Date): Error aborting rebase"
        }
        return  
    }

    git push -u origin $Branch
    if ($LASTEXITCODE -ne 0) {
        Add-Content -Path "auto_git.log" -Value "$(Get-Date): Error in git push"
    } else {
        Add-Content -Path "auto_git.log" -Value "$(Get-Date): Pushed successfully"
    }
}

$action = {
    $name = $Event.SourceEventArgs.Name
    $changeType = $Event.SourceEventArgs.ChangeType
    $fullPath = $Event.SourceEventArgs.FullPath
    $isDirectory = Test-Path $fullPath -PathType Container -ErrorAction SilentlyContinue

    if ($name -notmatch '(\.git\\|\.DS_Store|node_modules\\)') {
        if ($isDirectory) {
            if ($changeType -eq "Created") {
                $script:pendingCreatesFolder[$name] = $true
            } elseif ($changeType -eq "Deleted") {
                $script:pendingDeletesFolder[$name] = $true
            }
        } else {
            if ($changeType -eq "Created") {
                $script:pendingCreatesFile[$name] = $true
            } elseif ($changeType -eq "Changed") {
                $script:pendingChangesFile[$name] = $true
            } elseif ($changeType -eq "Deleted") {
                $script:pendingDeletesFile[$name] = $true
            }
        }
        Commit-AndPush
    }
}

Register-ObjectEvent $watcher "Created" -Action $action
Register-ObjectEvent $watcher "Changed" -Action $action
Register-ObjectEvent $watcher "Deleted" -Action $action
Register-ObjectEvent $watcher "Renamed" -Action {
    $oldName = $Event.SourceEventArgs.OldName
    $newName = $Event.SourceEventArgs.Name
    $fullPath = $Event.SourceEventArgs.FullPath
    $isDirectory = Test-Path $fullPath -PathType Container -ErrorAction SilentlyContinue
    if ($oldName -notmatch '(\.git\\|\.DS_Store|node_modules\\)') {
        if ($isDirectory) {
            $script:pendingDeletesFolder[$oldName] = $true
            $script:pendingCreatesFolder[$newName] = $true
        } else {
            $script:pendingDeletesFile[$oldName] = $true
            $script:pendingCreatesFile[$newName] = $true
        }
        Commit-AndPush
    }
}
try {
    while ($Global:Running) {
        Start-Sleep -Seconds 1
    }
} finally {
    $watcher.Dispose()
}