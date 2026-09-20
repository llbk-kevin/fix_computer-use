param(
    [ValidateSet('Status', 'Apply', 'Rollback')][string]$Mode = 'Status',
    [string]$NativeDirectory = (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node\df473e5367fa2b42\bin\node_modules\@oai\sky\bin\windows'),
    [string]$BackupDirectory = (Join-Path $PSScriptRoot '..\artifacts\backups\wgc-default-border-20260921')
)

# Local compatibility patch for one exact x64 executable hash.
# Keep the OS capture border by skipping the optional SetIsBorderRequired(false).
# This changes the executable's Authenticode hash; it is not an official update.
# No access checks, URL policies, app permissions or security settings are changed.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$nativeRoot = [IO.Path]::GetFullPath($NativeDirectory).TrimEnd('\')
$backupRoot = [IO.Path]::GetFullPath($BackupDirectory).TrimEnd('\')
$target = Join-Path $nativeRoot 'codex-computer-use.exe'
$backup = Join-Path $backupRoot 'codex-computer-use.original.exe'
$candidate = Join-Path $backupRoot 'codex-computer-use.compat.exe'
$manifest = Join-Path $backupRoot 'manifest.json'
$originalHash = 'd09a2f3f4c144be9c180509f5cd67d60f4b0b6fbb62e0f5a1ee131f4b653c512'
$patchedHash = '2c5bb0414f98e25f95b18cd18c2e7c2d64d1d820021b721b45b60b7ef4ec57eb'
$offset = 251911
$before = [byte[]](0x48,0x83,0x64,0x24,0x60,0x00)
$after = [byte[]](0xe9,0x95,0x00,0x00,0x00,0x90)

function File-Hash([string]$File) {
    return (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Save-State($State) {
    [IO.File]::WriteAllText($manifest, ($State | ConvertTo-Json -Depth 6) + [Environment]::NewLine, $utf8)
}

function Copy-AfterExit([string]$Source, [string]$Destination) {
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force
            return
        } catch [IO.IOException] {
            if ($attempt -eq 4) { throw }
            # Windows may briefly retain an executable image mapping after exit.
            Start-Sleep -Milliseconds 300
        }
    }
}

function Stop-ExactHelper {
    $matches = @(Get-CimInstance Win32_Process -Filter "Name = 'codex-computer-use.exe'" | Where-Object {
        $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $target
    })
    $roots = @($matches | Where-Object { $_.CommandLine -notmatch 'system-cursor-manager' })
    if ($roots.Count -gt 1) { throw 'Multiple helper roots found; refuse to interrupt multiple sessions.' }
    $children = @($matches | Where-Object { $_.CommandLine -match 'system-cursor-manager' })
    foreach ($child in $children) {
        if ($roots.Count -ne 1 -or $child.ParentProcessId -ne $roots[0].ProcessId) { throw 'Unrelated cursor helper found.' }
    }
    foreach ($item in $roots) {
        $process = Get-Process -Id $item.ProcessId -ErrorAction SilentlyContinue
        if ($process) {
            if ([IO.Path]::GetFullPath($process.Path) -ine $target) { throw 'Helper identity changed.' }
            Stop-Process -InputObject $process -Force
            $process.WaitForExit(10000) | Out-Null
            if (-not $process.HasExited) { throw 'Helper did not stop.' }
        }
    }
    foreach ($child in $children) {
        $process = Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue
        if ($process -and -not $process.WaitForExit(10000)) {
            throw 'Cursor helper has not finished restoring its state; it was not forcibly terminated.'
        }
    }
}

$currentHash = File-Hash $target
if ($Mode -eq 'Status') {
    [ordered]@{
        Target=$target
        Hash=$currentHash
        IsOriginal=($currentHash -ceq $originalHash)
        IsPatched=($currentHash -ceq $patchedHash)
        Signature=(Get-AuthenticodeSignature -LiteralPath $target).Status.ToString()
        BackupExists=(Test-Path -LiteralPath $backup)
    } | ConvertTo-Json
    exit 0
}

if ($Mode -eq 'Rollback') {
    if ($currentHash -cne $originalHash -and $currentHash -cne $patchedHash) { throw 'Executable changed; refuse to overwrite another version.' }
    $state = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.Target -ine $target -or $state.OriginalHash -cne $originalHash -or (File-Hash $backup) -cne $originalHash) {
        throw 'Backup manifest or checksum mismatch.'
    }
    Stop-ExactHelper
    Copy-AfterExit $backup $target
    if ((File-Hash $target) -cne $originalHash -or (Get-AuthenticodeSignature -LiteralPath $target).Status -ne 'Valid') {
        throw 'Rollback verification failed.'
    }
    $state.Status = 'rolled-back'
    Save-State $state
    Write-Output 'Original bytes and valid signature restored.'
    exit 0
}

if ($currentHash -cne $originalHash) { throw 'Executable version does not match the reviewed patch.' }
if ((Get-AuthenticodeSignature -LiteralPath $target).Status -ne 'Valid') { throw 'Original signature must be valid.' }
$api = [Windows.Foundation.Metadata.ApiInformation, Windows.Foundation, ContentType = WindowsRuntime]
if ($api::IsPropertyPresent('Windows.Graphics.Capture.GraphicsCaptureSession', 'IsBorderRequired')) {
    throw 'This OS provides IsBorderRequired; this legacy compatibility patch is not applicable.'
}
if (Test-Path -LiteralPath $backupRoot) { throw 'Backup directory already exists; preserve it and choose another.' }
$bytes = [IO.File]::ReadAllBytes($target)
for ($index=0; $index -lt $before.Length; $index++) {
    if ($bytes[$offset+$index] -ne $before[$index]) { throw 'Instruction bytes do not match the reviewed patch.' }
}
[IO.Directory]::CreateDirectory($backupRoot) | Out-Null
Copy-Item -LiteralPath $target -Destination $backup
if ((File-Hash $backup) -cne $originalHash) { throw 'Backup checksum failed.' }
[Array]::Copy($after, 0, $bytes, $offset, $after.Length)
[IO.File]::WriteAllBytes($candidate, $bytes)
if ((File-Hash $candidate) -cne $patchedHash) { throw 'Candidate checksum failed.' }
$state = [ordered]@{
    Schema=1;CreatedAt=(Get-Date).ToString('o');Target=$target;OriginalHash=$originalHash
    PatchedHash=$patchedHash;FileOffset=$offset;OriginalBytes='488364246000';PatchedBytes='e99500000090'
    Behavior='Keep default OS capture border; skip optional border-disable operation'
    SignatureImpact='Authenticode HashMismatch expected; no OS trust policy is changed'
    Status='prepared'
}
Save-State $state
Stop-ExactHelper
try {
    Copy-AfterExit $candidate $target
    if ((File-Hash $target) -cne $patchedHash) { throw 'Installed patch checksum failed.' }
    $state.Status = 'installed-validation-pending'
    Save-State $state
    Write-Output 'Version-pinned WGC compatibility patch installed. Validate with the official sky API.'
    Write-Output "Backup: $backupRoot"
} catch {
    Copy-AfterExit $backup $target
    $state.Status = 'deployment-failed-restored'
    Save-State $state
    throw
}
