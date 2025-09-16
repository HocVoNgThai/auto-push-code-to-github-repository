$folder = "C:\path\to\your\folder" #replace folder that you want tu auto update
$filter = "*.*"
$watcher = New-Object IO.FileSystemWatcher $folder, $filter -Property @{IncludeSubdirectories = $true;EnableRaisingEvents = $true}

Register-ObjectEvent $watcher "Changed" -Action {
    Set-Location $folder
    git add .
    git commit -m "Auto update $(Get-Date)"
    git push origin main
}
while ($true) { Start-Sleep 1 }