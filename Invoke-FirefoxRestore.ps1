param(
    [string]$AdbPath = "C:\Users\Andrew\platform-tools-install\platform-tools\adb.exe",
    [string]$DeviceSerial,
    [Parameter(Mandatory = $true)][string]$BackupFile,
    [string]$PackageId = "org.mozilla.firefox",
    [int]$RdpLocalPort = 6101
)

Import-Module (Join-Path $PSScriptRoot "FirefoxRdp.psm1") -Force

if (-not (Test-Path $BackupFile)) {
    throw "Backup file not found: $BackupFile"
}
$absBackupFile = [System.IO.Path]::GetFullPath($BackupFile)

$adbArgs = @()
if ($DeviceSerial) { $adbArgs += @("-s", $DeviceSerial) }

$remoteDir = "/sdcard/Android/data/$PackageId"
$remoteFile = "$remoteDir/firefox-android-backup.tar.gz"

Write-Host "[1/6] Pushing backup archive to device..."
& $AdbPath @adbArgs shell mkdir -p $remoteDir | Out-Null
& $AdbPath @adbArgs push $absBackupFile $remoteFile
if ($LASTEXITCODE -ne 0) { throw "adb push failed" }

Write-Host "[2/6] Setting up adb forward to Firefox DevTools socket..."
& $AdbPath @adbArgs forward tcp:$RdpLocalPort "localabstract:$PackageId/firefox-debugger-socket" | Out-Null

Write-Host "[3/6] Connecting to Firefox DevTools..."
$conn = New-RdpConnection -Port $RdpLocalPort
Write-Host "      Connected. applicationType=$($conn.Hello.applicationType)"

Write-Host "[4/6] Locating Main Process console actor..."
$consoleActor = Get-MainProcessConsoleActor -Conn $conn
Write-Host "      Console actor: $consoleActor"

Write-Host "[5/6] Loading payload and applying restore..."
$payload = Get-Content (Join-Path $PSScriptRoot "fab_rdp_payload.js") -Raw
Invoke-RdpEval -Conn $conn -ConsoleActor $consoleActor -Text $payload | Out-Null
$log = Invoke-RdpEval -Conn $conn -ConsoleActor $consoleActor -Text "fab_backup_restore_apply_v2()" -TimeoutSec 300
Write-Host "      Device-side log:"
Write-Host $log

Write-Host "[6/6] Restarting Firefox to complete restore..."
try {
    # Fire-and-forget: this kills the app, so the connection drops as a
    # side effect. We don't wait for a response.
    Send-RdpPacket -Stream $conn.Stream -Obj @{ to = $consoleActor; type = "evaluateJSAsync"; text = "fab_kill_app()" }
    Start-Sleep -Milliseconds 500
} catch {
    # Expected: connection dies when the app is killed.
}
try { Close-RdpConnection -Conn $conn } catch {}

# Clean up the pushed archive and log now that restore has been applied.
& $AdbPath @adbArgs shell rm -f "$remoteFile" "$remoteDir/firefox-android-backup.log" | Out-Null

Write-Host ""
Write-Host "SUCCESS: restore applied. Firefox was force-closed on the device; reopen it to verify."
