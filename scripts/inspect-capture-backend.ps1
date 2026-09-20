$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$processes = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(codex-computer-use.*|node_repl|codex|ChatGPT)\.exe$' } | Select-Object Name, ProcessId, ParentProcessId, ExecutablePath)
$packages = @(Get-AppxPackage -Name OpenAI.Codex | Select-Object Name, Version, InstallLocation)
$result = [ordered]@{ Processes = $processes; Packages = $packages }
$json = $result | ConvertTo-Json -Depth 5
$output = Join-Path $PSScriptRoot '..\artifacts\diagnostics\backend-inventory.json'
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($output))) | Out-Null
[IO.File]::WriteAllText([IO.Path]::GetFullPath($output), $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Output $json
