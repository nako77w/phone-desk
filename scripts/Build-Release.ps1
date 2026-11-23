param(
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version = '1.0.0',
    [string]$Compiler,
    [switch]$PortableOnly,
    [string]$DependencyCache
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$stage = Join-Path $root 'stage'
$dist = Join-Path $root 'dist'
$app = Join-Path $stage 'PhoneDesk'
$downloads = Join-Path $stage 'downloads'
$null = New-Item -ItemType Directory -Force $app,$dist,$downloads

function Get-ReleaseFile($name,$uri,$sha256) {
    $path = Join-Path $downloads $name
    if ($DependencyCache -and (Test-Path -LiteralPath (Join-Path $DependencyCache $name))) {
        Copy-Item -LiteralPath (Join-Path $DependencyCache $name) -Destination $path -Force
    } elseif (-not (Test-Path -LiteralPath $path) -or (Get-FileHash -LiteralPath $path).Hash -ne $sha256) {
        Invoke-WebRequest -Uri $uri -OutFile $path -UseBasicParsing
    }
    if ((Get-FileHash -LiteralPath $path).Hash -ne $sha256) {
        throw "SHA-256 mismatch: $name"
    }
    $path
}

$engine = Get-ReleaseFile 'scrcpy.zip' 'https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/scrcpy-win64-v5.0.1.zip' 'B12A2C4EE8BE317422451FC7DCF8EE20A71B5EA7EF9AD73DDD825A25316227A5'
$qrcode = Get-ReleaseFile 'qrcoder.zip' 'https://api.nuget.org/v3-flatcontainer/qrcoder/1.6.0/qrcoder.1.6.0.nupkg' 'D84BFFE9DECF1FA2B8755610407959F998209029C3B6B95A1B282CEB9983A36F'
Expand-Archive -LiteralPath $engine -DestinationPath (Join-Path $downloads 'scrcpy') -Force
Expand-Archive -LiteralPath $qrcode -DestinationPath (Join-Path $downloads 'qrcoder') -Force

$engineTarget = Join-Path $app 'engine'
$null = New-Item -ItemType Directory -Force $engineTarget
Copy-Item -Path (Join-Path $downloads 'scrcpy/scrcpy-win64-v5.0.1/*') -Destination $engineTarget -Force
Copy-Item -LiteralPath (Join-Path $downloads 'qrcoder/lib/net40/QRCoder.dll') -Destination $app -Force
Copy-Item -Path (Join-Path $root 'app/*') -Destination $app -Force
Copy-Item -LiteralPath (Join-Path $root 'third-party/QRCoder-LICENSE.txt') -Destination $app -Force

& powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $app 'PhoneDesk.ps1') -SelfTest
if ($LASTEXITCODE -ne 0) { throw 'PhoneDesk self-test failed' }

Compress-Archive -LiteralPath $app -DestinationPath (Join-Path $dist 'PhoneDesk-Portable-x64.zip') -Force
if (-not $PortableOnly) {
    if (-not $Compiler) {
        $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
        $Compiler = if ($command) { $command.Source } else { "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" }
    }
    if (-not (Test-Path -LiteralPath $Compiler)) { throw 'Inno Setup 6 compiler not found. Use -Compiler to specify ISCC.exe.' }
    & $Compiler "/DBuildVersion=$Version" (Join-Path $root 'installer/PhoneDesk.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Inno Setup compilation failed' }
}
Get-ChildItem -LiteralPath $dist -File | Where-Object Name -ne 'SHA256SUMS.txt' | Get-FileHash -Algorithm SHA256 | ForEach-Object {
    "$($_.Hash.ToLowerInvariant())  $([IO.Path]::GetFileName($_.Path))"
} | Set-Content -LiteralPath (Join-Path $dist 'SHA256SUMS.txt') -Encoding ascii
