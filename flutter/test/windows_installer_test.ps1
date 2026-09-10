param([Parameter(Mandatory=$true)][string]$Setup,
      [Parameter(Mandatory=$true)][string]$Archive)
$ErrorActionPreference = 'Stop'
$setupPath = (Resolve-Path $Setup).Path
$archivePath = (Resolve-Path $Archive).Path
$testParent = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp'
$root = Join-Path $testParent ('ChroMagician installer ' + [guid]::NewGuid())
$app = Join-Path $root 'app'
$exe = Join-Path $app 'chromatic_pc_backup.exe'
$registry = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ChroMagician_is1'
$startShortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'ChroMagician.lnk'
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ChroMagician.lnk'
$prefs = Join-Path $env:APPDATA ('chromagician-installer-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Force $prefs | Out-Null
Set-Content (Join-Path $prefs 'preferences') 'keep'
try {
    $install = Start-Process $setupPath -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/TASKS=desktopicon',"/DIR=`"$root`"") -Wait -PassThru
    if ($install.ExitCode -ne 0) { throw "Installation failed: $($install.ExitCode)" }
    foreach ($path in @($exe, $startShortcut, $desktopShortcut, (Join-Path $root 'uninstall/unins000.exe'))) {
        if (!(Test-Path $path)) { throw "Missing installed file: $path" }
    }
    $entry = Get-ItemProperty $registry
    if ($entry.InstallLocation.TrimEnd('\') -ne $root) { throw 'Wrong installed-app registration' }
    $shell = New-Object -ComObject WScript.Shell
    $shortcutTarget = $shell.CreateShortcut($startShortcut).TargetPath
    if ($shortcutTarget -ne $exe) { throw "Wrong shortcut target: $shortcutTarget (expected $exe)" }
    $uninstaller = Join-Path $root 'uninstall/unins000.exe'
    $before = (Get-FileHash $uninstaller).Hash
    $version = (Get-Content (Join-Path $app 'data/flutter_assets/version.json') | ConvertFrom-Json).version
    Set-Content (Join-Path $app 'data/flutter_assets/version.json') '{"version":"0.0.0"}'
    Set-ItemProperty $registry -Name DisplayVersion -Value '0.0.0'
    dart run test/support/installed_update_driver.dart $app $archivePath $version (Join-Path $root 'downloads')
    if ($LASTEXITCODE -ne 0) { throw 'Update handoff failed' }
    $deadline = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Milliseconds 200
        $stages = @(Get-ChildItem $root -Directory -Force | Where-Object Name -Like '.chromagician-update-*')
    } while ($stages.Count -and (Get-Date) -lt $deadline)
    if ($stages.Count) { throw 'Installed app did not complete startup/update cleanup' }
    if ((Get-FileHash $uninstaller).Hash -ne $before) { throw 'Updater changed the uninstaller' }
    if (!(Test-Path $registry) -or !(Test-Path $startShortcut)) { throw 'Update lost installation registration' }
    if ((Get-ItemProperty $registry).DisplayVersion -ne $version) { throw 'Update left an outdated version in Windows Settings' }
    Get-Process -Name chromatic_pc_backup -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | ForEach-Object { Stop-Process -Id $_.Id -Force; Wait-Process -Id $_.Id -ErrorAction SilentlyContinue }
    Set-Content (Join-Path $app 'added-by-update.txt') 'owned app file'
    $uninstall = Start-Process $uninstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') -Wait -PassThru
    if ($uninstall.ExitCode -ne 0) { throw "Uninstall failed: $($uninstall.ExitCode)" }
    if ((Test-Path $app) -or (Test-Path $registry) -or (Test-Path $startShortcut) -or (Test-Path $desktopShortcut)) { throw 'Uninstall left app files or registration' }
    if ((Get-Content (Join-Path $prefs 'preferences')) -ne 'keep') { throw 'Uninstall changed user data' }
    Write-Output 'PASS Windows installer: install, shortcuts, registration, production update, preserved uninstaller, complete uninstall, retained user data'
} finally {
    Get-Process -Name chromatic_pc_backup -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | ForEach-Object { Stop-Process -Id $_.Id -Force; Wait-Process -Id $_.Id -ErrorAction SilentlyContinue }
    if (Test-Path (Join-Path $root 'uninstall/unins000.exe')) {
        Start-Process (Join-Path $root 'uninstall/unins000.exe') -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') -Wait | Out-Null
    }
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $prefs -Recurse -Force
}
