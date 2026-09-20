$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$items = @(Get-CimInstance Win32_Process -Filter "Name = 'codex-computer-use.exe'")
$items | ForEach-Object {
    [PSCustomObject]@{
        ProcessId=$_.ProcessId
        ParentProcessId=$_.ParentProcessId
        Path=$_.ExecutablePath
        Created=$_.CreationDate
        IsCursorManager=($_.CommandLine -match 'system-cursor-manager')
        ParentProcessName=(Get-Process -Id $_.ParentProcessId -ErrorAction SilentlyContinue).ProcessName
    }
} | ConvertTo-Json -Depth 4
