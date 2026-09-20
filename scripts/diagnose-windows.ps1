param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\artifacts\diagnostics\windows.json')
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Read-WinRTCapability {
    try {
        $api = [Windows.Foundation.Metadata.ApiInformation, Windows.Foundation, ContentType = WindowsRuntime]
        $captureType = 'Windows.Graphics.Capture.GraphicsCaptureSession'
        $capture = [Windows.Graphics.Capture.GraphicsCaptureSession, Windows.Graphics.Capture, ContentType = WindowsRuntime]
        return [ordered]@{
            TypePresent = $api::IsTypePresent($captureType)
            IsSupported = $capture::IsSupported()
            IsBorderRequired = $api::IsPropertyPresent($captureType, 'IsBorderRequired')
            IsCursorCaptureEnabled = $api::IsPropertyPresent($captureType, 'IsCursorCaptureEnabled')
            UniversalApiContractV12 = $api::IsApiContractPresent('Windows.Foundation.UniversalApiContract', 12)
        }
    } catch {
        return [ordered]@{ Error = $_.Exception.ToString() }
    }
}

$version = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$result = [ordered]@{
    CollectedAt = (Get-Date).ToString('o')
    OS = [ordered]@{
        ProductName = $version.ProductName
        EditionID = $version.EditionID
        DisplayVersion = $version.DisplayVersion
        CurrentBuild = $version.CurrentBuildNumber
        UBR = $version.UBR
        Architecture = $env:PROCESSOR_ARCHITECTURE
    }
    PowerShell = $PSVersionTable.PSVersion.ToString()
    UserInteractive = [Environment]::UserInteractive
    SessionId = (Get-Process -Id $PID).SessionId
    GraphicsCapture = Read-WinRTCapability
    Kernel = Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture, LastBootUpTime
    KernelFileVersion = (Get-Item (Join-Path $env:SystemRoot 'System32\ntoskrnl.exe')).VersionInfo.FileVersion
    VideoControllers = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, DriverDate, Status, CurrentHorizontalResolution, CurrentVerticalResolution)
    RecentHotfixes = @(Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5 HotFixID, @{Name='InstalledOn';Expression={if ($_.InstalledOn) { $_.InstalledOn.ToString('yyyy-MM-dd') }}})
    DotNetFrameworkRelease = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
    VCRuntimeX64 = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue | Select-Object Installed, Version
    AppPackage = @(Get-AppxPackage -Name OpenAI.Codex | Select-Object Name, Version, Architecture, Status)
    PendingRestart = [ordered]@{
        ComponentServicing = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        WindowsUpdate = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    }
}
$fullPath = [IO.Path]::GetFullPath($OutputPath)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath)) | Out-Null
$json = $result | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($fullPath, $json + [Environment]::NewLine, $utf8)
Write-Output $json
