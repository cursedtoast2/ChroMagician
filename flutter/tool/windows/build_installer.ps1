param([Parameter(Mandatory=$true)][string]$Bundle,
      [Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference = 'Stop'
$bundlePath = (Resolve-Path $Bundle).Path
New-Item -ItemType Directory -Force $Output | Out-Null
$outputPath = (Resolve-Path $Output).Path
$version = (Get-Content (Join-Path $bundlePath 'data/flutter_assets/version.json') | ConvertFrom-Json).version
if ($version -notmatch '^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?$') { throw 'Invalid release version' }
$compilerRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../.dart_tool/inno-7.1.0'))
$compiler = Join-Path $compilerRoot 'ISCC.exe'
if (!(Test-Path $compiler)) {
    $download = Join-Path $env:TEMP 'chromagician-innosetup-7.1.0-x64.exe'
    Invoke-WebRequest 'https://github.com/jrsoftware/issrc/releases/download/is-7_1_0/innosetup-7.1.0-x64.exe' -OutFile $download
    if ((Get-FileHash $download -Algorithm SHA256).Hash -ne '0362a383ed217d4c4239b5933866dd96d3eb2102737da92f80f6057a4b40df2f') {
        throw 'Inno Setup download checksum mismatch'
    }
    $install = Start-Process $download -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/DIR=`"$compilerRoot`"") -Wait -PassThru
    if ($install.ExitCode -ne 0) { throw "Inno Setup installation failed: $($install.ExitCode)" }
    Remove-Item $download
}
& $compiler "/DBundleDir=$bundlePath" "/DReleaseVersion=$version" "/DOutputDir=$outputPath" (Join-Path $PSScriptRoot 'installer.iss')
if ($LASTEXITCODE -ne 0) { throw 'Windows installer compilation failed' }
$setup = Get-Item (Join-Path $outputPath "ChroMagician-$version-windows-x64-Setup.exe")
$hash = (Get-FileHash $setup -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$($setup.FullName).sha256", "$hash  $($setup.Name)`n")
Write-Output "Built installer: $($setup.FullName)"
