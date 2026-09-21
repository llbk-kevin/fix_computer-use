param(
    [ValidateSet('Status', 'Apply', 'Rollback')][string]$Mode = 'Status',
    [string]$NativeDirectory = (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node\df473e5367fa2b42\bin\node_modules\@oai\sky\bin\windows'),
    [string]$BuildDirectory = (Join-Path $PSScriptRoot '..\artifacts\build\wgc-readback-v2'),
    [string]$BackupDirectory = (Join-Path $PSScriptRoot '..\artifacts\backups\wgc-readback-validated-20260921')
)

# 仅部署已经独立验证的特定版本；保留原程序完整备份与现有应用授权流程。
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$nativeRoot = [IO.Path]::GetFullPath($NativeDirectory).TrimEnd('\')
$buildRoot = [IO.Path]::GetFullPath($BuildDirectory).TrimEnd('\')
$backupRoot = [IO.Path]::GetFullPath($BackupDirectory).TrimEnd('\')
$target = Join-Path $nativeRoot 'codex-computer-use.exe'
$dll = Join-Path $nativeRoot 'codex-wgc-readback.dll'
$original = Join-Path $backupRoot 'codex-computer-use.original.exe'
$statePath = Join-Path $backupRoot 'manifest.json'
$originalHash = 'd09a2f3f4c144be9c180509f5cd67d60f4b0b6fbb62e0f5a1ee131f4b653c512'
$patchedHash = 'c29ad8f38b58a347ef177ab7706de1fc2e345b3450cc921a4973f3cb5070c666'
$dllHash = '04edc7abd9f1916b185eaaa82b5055a28b7c5e324d51e6ab9fcc73e057330c97'

function File-Hash([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Save-State($State) {
    [IO.File]::WriteAllText($statePath, ($State | ConvertTo-Json -Depth 5) + [Environment]::NewLine, $utf8)
}

function Copy-AfterExit([string]$Source, [string]$Destination) {
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        try { Copy-Item -LiteralPath $Source -Destination $Destination -Force; return }
        catch [IO.IOException] {
            if ($attempt -eq 7) { throw }
            Start-Sleep -Milliseconds 300
        }
    }
}

function Stop-ExactHelper {
    $matches = @(Get-CimInstance Win32_Process -Filter "Name = 'codex-computer-use.exe'" | Where-Object {
        $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $target
    })
    $roots = @($matches | Where-Object { $_.CommandLine -notmatch 'system-cursor-manager' })
    $children = @($matches | Where-Object { $_.CommandLine -match 'system-cursor-manager' })
    if ($roots.Count -gt 1) { throw 'Multiple helper sessions found; no process was stopped.' }
    foreach ($child in $children) {
        if ($roots.Count -ne 1 -or $child.ParentProcessId -ne $roots[0].ProcessId) { throw 'Unrelated cursor helper found.' }
    }
    foreach ($entry in $roots) {
        $process = Get-Process -Id $entry.ProcessId -ErrorAction SilentlyContinue
        if ($process) {
            if ([IO.Path]::GetFullPath($process.Path) -ine $target) { throw 'Helper identity changed.' }
            Stop-Process -InputObject $process -Force
            if (-not $process.WaitForExit(10000)) { throw 'Helper did not exit.' }
        }
    }
    foreach ($entry in $children) {
        $process = Get-Process -Id $entry.ProcessId -ErrorAction SilentlyContinue
        if ($process -and -not $process.WaitForExit(10000)) { throw 'Cursor helper has not finished its own cleanup.' }
    }
}

$currentHash = File-Hash $target
if ($Mode -eq 'Status') {
    [ordered]@{
        Target=$target;Hash=$currentHash;IsOriginal=($currentHash -ceq $originalHash)
        IsReadbackCompat=($currentHash -ceq $patchedHash);CompanionMatches=((File-Hash $dll) -ceq $dllHash)
        Signature=(Get-AuthenticodeSignature -LiteralPath $target).Status.ToString()
        BackupExists=(Test-Path -LiteralPath $original)
    } | ConvertTo-Json
    exit 0
}

if ($Mode -eq 'Rollback') {
    $state = Get-Content -LiteralPath $statePath -Encoding UTF8 -Raw | ConvertFrom-Json
    if ($state.Schema -ne 1 -or $state.Target -ine $target -or $state.OriginalHash -cne $originalHash -or $state.PatchedHash -cne $patchedHash -or $state.CompanionHash -cne $dllHash -or (File-Hash $original) -cne $originalHash) { throw 'Backup does not match this installation.' }
    if ($currentHash -cne $originalHash -and $currentHash -cne $patchedHash) { throw 'Another native version is installed; refuse to overwrite it.' }
    if ((Test-Path -LiteralPath $dll) -and (File-Hash $dll) -cne $dllHash) { throw 'Companion DLL changed; refuse to remove it.' }
    Stop-ExactHelper
    if ((File-Hash $target) -cne $currentHash) { throw 'Native program changed while stopping; no restoration was performed.' }
    Copy-AfterExit $original $target
    if ((File-Hash $target) -cne $originalHash -or (Get-AuthenticodeSignature -LiteralPath $target).Status -ne 'Valid') { throw 'Original program restoration failed verification.' }
    if (Test-Path -LiteralPath $dll) {
        if ((File-Hash $dll) -cne $dllHash) { throw 'Companion changed while stopping; it was not removed.' }
        Remove-Item -LiteralPath $dll
    }
    $state.Status = 'rolled-back'; Save-State $state
    Write-Output 'Original program and valid signature restored; compatibility DLL removed.'
    exit 0
}

if ($currentHash -cne $originalHash -or (Get-AuthenticodeSignature -LiteralPath $target).Status -ne 'Valid') { throw 'Expected original signed program is not installed.' }
if (Test-Path -LiteralPath $backupRoot) { throw 'Backup directory exists; preserve it and choose a fresh directory.' }
if (Test-Path -LiteralPath $dll) { throw 'Companion destination already exists; refuse to overwrite it.' }
$candidate = Join-Path $buildRoot 'codex-computer-use.compat.exe'
$candidateDll = Join-Path $buildRoot 'codex-wgc-readback.dll'
if ((File-Hash $candidate) -cne $patchedHash -or (File-Hash $candidateDll) -cne $dllHash) { throw 'Candidate files do not match the reviewed build.' }
$api = [Windows.Foundation.Metadata.ApiInformation, Windows.Foundation, ContentType = WindowsRuntime]
if ($api::IsPropertyPresent('Windows.Graphics.Capture.GraphicsCaptureSession', 'IsBorderRequired')) { throw 'This compatibility build is limited to the verified older Windows API set.' }
[IO.Directory]::CreateDirectory($backupRoot) | Out-Null
Copy-Item -LiteralPath $target -Destination $original
if ((File-Hash $original) -cne $originalHash) { throw 'Backup checksum verification failed.' }
$state = [ordered]@{
    Schema=1;CreatedAt=(Get-Date).ToString('o');Target=$target;OriginalHash=$originalHash
    PatchedHash=$patchedHash;CompanionHash=$dllHash;Status='prepared'
}
Save-State $state
Stop-ExactHelper
if ((File-Hash $target) -cne $originalHash -or (Test-Path -LiteralPath $dll)) { throw 'Installation changed while stopping; no candidate was copied.' }
try {
    Copy-AfterExit $candidateDll $dll
    Copy-AfterExit $candidate $target
    if ((File-Hash $target) -cne $patchedHash -or (File-Hash $dll) -cne $dllHash) { throw 'Installed file checksums do not match.' }
    $state.Status = 'installed-validation-pending'; Save-State $state
    Write-Output 'WGC readback compatibility build installed; official sky screenshot validation is required.'
} catch {
    $failure = $_
    Copy-AfterExit $original $target
    if ((File-Hash $dll) -ceq $dllHash) { Remove-Item -LiteralPath $dll }
    $state.Status = 'deployment-failed-restored'; Save-State $state
    throw $failure
}
