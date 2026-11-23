param(
    [Parameter(Mandatory)][string]$AndroidSdk,
    [Parameter(Mandatory)][string]$JavaHome,
    [Parameter(Mandatory)][string]$KeyStore,
    [string]$Output = 'PhoneDesk-Android.apk'
)
$ErrorActionPreference = 'Stop'
$env:JAVA_HOME = (Resolve-Path -LiteralPath $JavaHome).Path
$tools = Join-Path $AndroidSdk 'build-tools/36.0.0'
$platform = Join-Path $AndroidSdk 'platforms/android-35/android.jar'
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'android'
$build = Join-Path (Split-Path -Parent $PSScriptRoot) 'stage/android'
$classes = Join-Path $build 'classes'
$dex = Join-Path $build 'dex'
$null = New-Item -ItemType Directory -Force $classes,$dex
$unsigned = Join-Path $build 'unsigned.apk'
$aligned = Join-Path $build 'aligned.apk'
$sources = @(Get-ChildItem -LiteralPath (Join-Path $source 'src') -Filter '*.java' -Recurse | ForEach-Object FullName)
function Invoke-BuildTool($file, [string[]]$arguments) {
    & $file @arguments
    if ($LASTEXITCODE -ne 0) { throw "Build tool failed: $file ($LASTEXITCODE)" }
}
Invoke-BuildTool (Join-Path $env:JAVA_HOME 'bin/javac.exe') (@('--release','8','-encoding','UTF-8','-classpath',$platform,'-d',$classes) + $sources)
$compiled = @(Get-ChildItem -LiteralPath $classes -Filter '*.class' -Recurse | ForEach-Object FullName)
Invoke-BuildTool (Join-Path $tools 'd8.bat') (@('--lib',$platform,'--min-api','30','--output',$dex) + $compiled)
Invoke-BuildTool (Join-Path $tools 'aapt.exe') @('package','-f','-M',(Join-Path $source 'AndroidManifest.xml'),'-S',(Join-Path $source 'res'),'-I',$platform,'-F',$unsigned)
Push-Location $dex
try { Invoke-BuildTool (Join-Path $tools 'aapt.exe') @('add',$unsigned,'classes.dex') }
finally { Pop-Location }
Invoke-BuildTool (Join-Path $tools 'zipalign.exe') @('-f','4',$unsigned,$aligned)
Invoke-BuildTool (Join-Path $tools 'apksigner.bat') @('sign','--ks',$KeyStore,'--ks-key-alias','phonedesk','--ks-pass','env:PHONEDESK_KEY_PASSWORD','--out',$Output,$aligned)
Invoke-BuildTool (Join-Path $tools 'apksigner.bat') @('verify','--verbose',$Output)
