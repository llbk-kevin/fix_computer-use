param(
    [ValidateSet('Status', 'Apply', 'Rollback')][string]$Mode = 'Status',
    [string]$NativeDirectory = (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node\df473e5367fa2b42\bin\node_modules\@oai\sky\bin\windows'),
    [string]$BackupDirectory = (Join-Path $PSScriptRoot '..\artifacts\backups\swift-backend-20260921')
)

# Version-pinned local switch between two unmodified, signed, bundled backends.
# No helper is launched here; the official application owns its lifecycle.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$nativeRoot = [IO.Path]::GetFullPath($NativeDirectory).TrimEnd('\')
$backupRoot = [IO.Path]::GetFullPath($BackupDirectory).TrimEnd('\')
$targetExecutable = Join-Path $nativeRoot 'codex-computer-use.exe'
$manifestPath = Join-Path $backupRoot 'manifest.json'
$originalHash = 'd09a2f3f4c144be9c180509f5cd67d60f4b0b6fbb62e0f5a1ee131f4b653c512'
$specs = @(
    @{Name='codex-computer-use.exe';Source='codex-computer-use-swift.exe';Hash='0b7cc4470027d04c37821c1fc61039853856d024343d04d37d66d9c0e0281d57'},
    @{Name='MSVCP140.dll';Source='MSVCP140.dll';Hash='6d5e28d4e0e5c3448ae44264b90aad6cfd9c3ef7cc1c21752b4dac6a4b633e1b'},
    @{Name='VCRUNTIME140.dll';Source='VCRUNTIME140.dll';Hash='e880dce457d80abbb427b5fc671c361b178bd2f0a497c8b7becf0c5c8044e0ec'},
    @{Name='VCRUNTIME140_1.dll';Source='VCRUNTIME140_1.dll';Hash='f8bf50114d49700d069563bd35a0520679bec32ad04b43287bd7e56ba513bba1'}
)

function File-Hash([string]$File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Manifest($State) {
    [IO.File]::WriteAllText($manifestPath, ($State | ConvertTo-Json -Depth 8) + [Environment]::NewLine, $utf8)
}

function Stop-TargetHelper {
    $matches = @(Get-CimInstance Win32_Process -Filter "Name = 'codex-computer-use.exe'" | Where-Object {
        $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $targetExecutable
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
            # Recheck the path to avoid acting on a reused PID.
            if ([IO.Path]::GetFullPath($process.Path) -ine $targetExecutable) { throw 'Helper process identity changed.' }
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

if ($Mode -eq 'Status') {
    [ordered]@{
        NativeDirectory=$nativeRoot
        ActiveFileHash=(File-Hash $targetExecutable)
        OriginalHash=$originalHash
        SwiftHash=$specs[0].Hash
        ManifestExists=(Test-Path -LiteralPath $manifestPath)
        Signature=(Get-AuthenticodeSignature -LiteralPath $targetExecutable).Status.ToString()
    } | ConvertTo-Json
    exit 0
}

if ($Mode -eq 'Rollback') {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Backup manifest is missing.' }
    $state = Get-Content -LiteralPath $manifestPath -Encoding UTF8 -Raw | ConvertFrom-Json
    if ($state.NativeDirectory -ine $nativeRoot -or $state.Schema -ne 1) { throw 'Backup manifest does not match this installation.' }
    if (@($state.Files).Count -ne $specs.Count) { throw 'Unexpected backup manifest file count.' }
    foreach ($spec in $specs) {
        $entry = @($state.Files | Where-Object { $_.Name -ceq $spec.Name })
        if ($entry.Count -ne 1 -or $entry[0].InstalledHash -cne $spec.Hash) { throw 'Unexpected backup manifest entry.' }
        $entry = $entry[0]
        $destination = Join-Path $nativeRoot $spec.Name
        $currentHash = File-Hash $destination
        if ($null -ne $currentHash -and $currentHash -cne $spec.Hash -and $currentHash -cne $entry.OriginalHash) {
            throw "File changed since deployment; refuse to overwrite: $destination"
        }
        if ($entry.Existed -and (File-Hash (Join-Path $backupRoot $spec.Name)) -cne $entry.OriginalHash) {
            throw "Backup checksum failed: $($spec.Name)"
        }
    }
    Stop-TargetHelper
    foreach ($spec in $specs) {
        $entry = $state.Files | Where-Object { $_.Name -ceq $spec.Name }
        $destination = Join-Path $nativeRoot $spec.Name
        if ($entry.Existed) {
            Copy-Item -LiteralPath (Join-Path $backupRoot $spec.Name) -Destination $destination -Force
        } elseif (Test-Path -LiteralPath $destination) {
            # Only this allow-listed file is removed; no recursive deletion is used.
            Remove-Item -LiteralPath $destination
        }
    }
    if ((File-Hash $targetExecutable) -cne $originalHash) { throw 'Restored executable checksum failed.' }
    $state.Status = 'rolled-back'
    Write-Manifest $state
    Write-Output 'Original signed backend restored. Re-enumerate windows through the official sky API.'
    exit 0
}

if ((File-Hash $targetExecutable) -cne $originalHash) { throw 'Unexpected installed version; no files were changed.' }
if (Test-Path -LiteralPath $backupRoot) { throw 'Backup directory already exists; use a new directory to preserve the previous backup.' }

# Verify every source before creating the backup or touching the live installation.
foreach ($spec in $specs) {
    $source = Join-Path (Join-Path $nativeRoot 'swift\x64') $spec.Source
    if ((File-Hash $source) -cne $spec.Hash) { throw "Unexpected source checksum: $source" }
    $signature = Get-AuthenticodeSignature -LiteralPath $source
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'OpenAI OpCo') {
        throw "Source signature is not valid: $source"
    }
}

[IO.Directory]::CreateDirectory($backupRoot) | Out-Null
$entries = foreach ($spec in $specs) {
    $destination = Join-Path $nativeRoot $spec.Name
    $oldHash = File-Hash $destination
    if ($null -ne $oldHash) {
        Copy-Item -LiteralPath $destination -Destination (Join-Path $backupRoot $spec.Name)
        if ((File-Hash (Join-Path $backupRoot $spec.Name)) -cne $oldHash) { throw 'Backup checksum failed.' }
    }
    [ordered]@{Name=$spec.Name;Existed=($null -ne $oldHash);OriginalHash=$oldHash;InstalledHash=$spec.Hash}
}
$state = [ordered]@{
    Schema=1;CreatedAt=(Get-Date).ToString('o');NativeDirectory=$nativeRoot
    Status='prepared';Files=@($entries)
}
Write-Manifest $state
Stop-TargetHelper
try {
    foreach ($spec in $specs) {
        $source = Join-Path (Join-Path $nativeRoot 'swift\x64') $spec.Source
        $destination = Join-Path $nativeRoot $spec.Name
        Copy-Item -LiteralPath $source -Destination $destination -Force
        if ((File-Hash $destination) -cne $spec.Hash) { throw "Installed checksum failed: $destination" }
    }
    if ((Get-AuthenticodeSignature -LiteralPath $targetExecutable).Status -ne 'Valid') { throw 'Installed signature validation failed.' }
    $state.Status = 'installed-validation-pending'
    Write-Manifest $state
    Write-Output 'Signed Swift backend installed. Validate using the official sky API before marking the repair successful.'
    Write-Output "Backup: $backupRoot"
} catch {
    $deploymentError = $_
    foreach ($entry in $entries) {
        $destination = Join-Path $nativeRoot $entry.Name
        if ($entry.Existed) {
            Copy-Item -LiteralPath (Join-Path $backupRoot $entry.Name) -Destination $destination -Force
        } elseif ((File-Hash $destination) -ceq $entry.InstalledHash) {
            Remove-Item -LiteralPath $destination
        }
    }
    $state.Status = 'deployment-failed-restored'
    Write-Manifest $state
    throw $deploymentError
}
