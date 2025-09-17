$ErrorActionPreference = "Stop"

param (
    [string]$Path = (Split-Path -Parent $MyInvocation.MyCommand.Path),
    [string]$Branch = "main",
    [int]$Delay = 10
)

$MonitorPath = (Resolve-Path $Path -ErrorAction Stop).Path

$LogFile = "$env:TEMP\auto_git_$(Get-Date -Format 'yyyyMMddHHmmss').log"

if (-not (Test-Path $MonitorPath -PathType Container)) {
    Write-Error "$MonitorPath is not a valid directory"
    Add-Content -Path $LogFile -Value "$(Get-Date): Error: $MonitorPath is not a valid directory"
    exit 1
}

if (-not (Test-Path (Join-Path $MonitorPath ".git") -PathType Container)) {
    Write-Error "$MonitorPath is not a Git repository"
    Add-Content -Path $LogFile -Value "$(Get-Date): Error: $MonitorPath is not a Git repository"
    exit 1
}

Set-Location $MonitorPath
Write-Host "Monitoring directory: $MonitorPath"
Add-Content -Path $LogFile -Value "$(Get-Date): Monitoring directory: $MonitorPath"

$Global:Running = $true
$SIGINTHandler = {
    Add-Content -Path $LogFile -Value "$(Get-Date): Stopping script..."
    $Global:Running = $false
}
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action $SIGINTHandler

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $MonitorPath
$watcher.IncludeSubdirectories = $true
$watcher.EnableRaisingEvents = $true
$watcher.Filter = "*.*"
$watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::DirectoryName -bor [System.IO.NotifyFilters]::LastWrite

$lastEventTime = Get-Date
$debounceSeconds = $Delay
$pendingCreatesFile = @{}
$pendingCreatesFolder = @{}
$pendingChangesFile = @{}
$pendingDeletesFile = @{}
$pendingDeletesFolder = @{}

function Handle-UnstagedChanges {
    $gitStatus = git status --porcelain
    if ($gitStatus | Where-Object { $_ -and -not $_.StartsWith('??') -and $_ -notmatch 'auto_git.*\.log' }) {
        Add-Content -Path $LogFile -Value "$(Get-Date): Unstaged changes detected. Committing them..."
        try {
            git add .
            if ($LASTEXITCODE -ne 0) {
                throw "Error in git add"
            }
            git commit -m "Auto commit unstaged changes"
            if ($LASTEXITCODE -ne 0) {
                throw "Error in git commit"
            }
            Add-Content -Path $LogFile -Value "$(Get-Date): Committed unstaged changes"
        } catch {
            Add-Content -Path $LogFile -Value "$(Get-Date): Error in committing unstaged changes: $_"
            return $false
        }
    }
    return $true
}

function Check-UpToDate {
    try {
        git fetch origin
        if ($LASTEXITCODE -ne 0) {
            throw "Error in git fetch"
        }
        $statusOutput = git status
        if ($statusOutput -match "Your branch is up to date with 'origin/$Branch'") {
            Add-Content -Path $LogFile -Value "$(Get-Date): No pull needed (already up to date)"
            return $true
        }
    } catch {
        Add-Content -Path $LogFile -Value "$(Get-Date): Error in git fetch: $_"
        return $false
    }
    return $false
}

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
            if ($path -match 'auto_git.*\.log') {
                continue
            }
            $name = [System.IO.Path]::GetFileName($path)
            if (Test-Path $path -PathType Container -ErrorAction SilentlyContinue) {
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
                if (Test-Path $newPath -PathType Container -ErrorAction SilentlyContinue) {
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
    if ($gitStatus -and ($gitStatus | Where-Object { $_ -notmatch 'auto_git.*\.log' })) {
        git add .
        if ($LASTEXITCODE -ne 0) {
            Add-Content -Path $LogFile -Value "$(Get-Date): Error in git add"
            return
        }
        $commitMessage = Generate-CommitMessage
        if ($commitMessage) {
            git commit -m $commitMessage
            if ($LASTEXITCODE -ne 0) {
                Add-Content -Path $LogFile -Value "$(Get-Date): Error in git commit: $commitMessage"
                return
            }
            Add-Content -Path $LogFile -Value "$(Get-Date): Committed: $commitMessage"
        }
    }

    if (Check-UpToDate) {
        git push origin $Branch
        if ($LASTEXITCODE -ne 0) {
            Add-Content -Path $LogFile -Value "$(Get-Date): Error in git push"
        } else {
            Add-Content -Path $LogFile -Value "$(Get-Date): Pushed successfully"
        }
        return
    }

    if (-not (Handle-UnstagedChanges)) {
        return
    }
    $pullOutput = git pull --ff-only origin $Branch 2>&1
    if ($LASTEXITCODE -ne 0) {
        Add-Content -Path $LogFile -Value "$(Get-Date): Pull failed (fast-forward): $pullOutput"
        $pullOutput = git pull --rebase origin $Branch 2>&1
        if ($LASTEXITCODE -ne 0) {
            Add-Content -Path $LogFile -Value "$(Get-Date): Pull failed (rebase): $pullOutput"
            Add-Content -Path $LogFile -Value "$(Get-Date): Resolve conflict manually with 'git rebase origin/$Branch' or 'git merge origin/$Branch'"
            git rebase --abort 2>&1 | Out-Null
            return
        }
    }

    git push origin $Branch
    if ($LASTEXITCODE -ne 0) {
        Add-Content -Path $LogFile -Value "$(Get-Date): Error in git push"
    } else {
        Add-Content -Path $LogFile -Value "$(Get-Date): Pushed successfully"
    }
}

$action = {
    $name = $Event.SourceEventArgs.Name
    $changeType = $Event.SourceEventArgs.ChangeType
    $fullPath = $Event.SourceEventArgs.FullPath
    $isDirectory = Test-Path $fullPath -PathType Container -ErrorAction SilentlyContinue

    if ($name -notmatch '(\.git\\|\.DS_Store|node_modules\\|auto_git.*\.log)') {
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
    if ($oldName -notmatch '(\.git\\|\.DS_Store|node_modules\\|auto_git.*\.log)') {
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