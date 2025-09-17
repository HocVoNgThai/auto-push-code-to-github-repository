$ErrorActionPreference = "Stop"

param (
    [string]$Path = (Split-Path -Parent $MyInvocation.MyCommand.Path)
)

$MonitorPath = (Resolve-Path $Path -ErrorAction Stop).Path

if (-not (Test-Path $MonitorPath -PathType Container)) {
    Write-Error "$MonitorPath is not a valid directory"
    exit 1
}

if (-not (Test-Path (Join-Path $MonitorPath ".git") -PathType Container)) {
    Write-Error "$MonitorPath is not a Git repository"
    exit 1
}

Set-Location $MonitorPath
Write-Host "Monitoring directory: $MonitorPath"

$Global:Running = $true
$SIGINTHandler = {
    Write-Host "Stopping script..."
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
$debounceSeconds = 5
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
    if ((Get-Date) - $lastEventTime -lt [TimeSpan]::FromSeconds($debounceSeconds)) {
        return
    }
    $script:lastEventTime = Get-Date

    $gitStatus = git status --porcelain
    if ($gitStatus) {
        git add .
        $commitMessage = Generate-CommitMessage
        if ($commitMessage) {
            git commit -m $commitMessage
            git push -u origin main
        }
    }

    $script:pendingCreatesFile.Clear()
    $script:pendingCreatesFolder.Clear()
    $script:pendingChangesFile.Clear()
    $script:pendingDeletesFile.Clear()
    $script:pendingDeletesFolder.Clear()
}

$action = {
    $name = $Event.SourceEventArgs.Name
    $changeType = $Event.SourceEventArgs.ChangeType
    $isDirectory = Test-Path (Join-Path $Event.SourceEventArgs.FullPath) -PathType Container

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
    $isDirectory = Test-Path (Join-Path $Event.SourceEventArgs.FullPath) -PathType Container
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