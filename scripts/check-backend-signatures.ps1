param([Parameter(Mandatory=$true)][string]$NativeDirectory)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$relativePaths = @('codex-computer-use.exe', 'swift\x64\codex-computer-use-swift.exe', 'swift\x64\MSVCP140.dll', 'swift\x64\VCRUNTIME140.dll', 'swift\x64\VCRUNTIME140_1.dll')
$result = foreach ($relative in $relativePaths) {
    $file = Join-Path $NativeDirectory $relative
    $signature = Get-AuthenticodeSignature -LiteralPath $file
    [PSCustomObject]@{
        RelativePath = $relative
        SHA256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        Length = (Get-Item -LiteralPath $file).Length
        SignatureStatus = $signature.Status.ToString()
        Signer = $signature.SignerCertificate.Subject
    }
}
$result | ConvertTo-Json -Depth 4
