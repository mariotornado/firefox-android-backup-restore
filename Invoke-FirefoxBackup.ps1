param(
    [string]$AdbPath = "C:\Users\Andrew\platform-tools-install\platform-tools\adb.exe",
    [string]$DeviceSerial,
    [string]$OutFile = "firefox-android-backup-auto.tar.gz",
    [string]$PackageId = "org.mozilla.firefox",
    [int]$RdpLocalPort = 6100,
    [int]$FabPort = 12101
)

Import-Module (Join-Path $PSScriptRoot "FirefoxRdp.psm1") -Force

$adbArgs = @()
if ($DeviceSerial) { $adbArgs += @("-s", $DeviceSerial) }

Write-Host "[1/6] Setting up adb forwards..."
& $AdbPath @adbArgs forward tcp:$RdpLocalPort "localabstract:$PackageId/firefox-debugger-socket" | Out-Null
& $AdbPath @adbArgs reverse tcp:$FabPort tcp:$FabPort | Out-Null

Write-Host "[2/6] Starting local TCP listener for backup stream..."
$listenerScript = {
    param($Port, $OutFile)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    $client = $listener.AcceptTcpClient()
    $stream = $client.GetStream()
    $fileStream = [System.IO.File]::Create($OutFile)
    $buffer = New-Object byte[] 65536
    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $fileStream.Write($buffer, 0, $read)
    }
    $fileStream.Close()
    $client.Close()
    $listener.Stop()
}
$absOutFile = [System.IO.Path]::GetFullPath($OutFile)
$job = Start-Job -ScriptBlock $listenerScript -ArgumentList $FabPort, $absOutFile

Start-Sleep -Milliseconds 500

Write-Host "[3/6] Connecting to Firefox DevTools over adb-forwarded socket..."
$conn = New-RdpConnection -Port $RdpLocalPort
Write-Host "      Connected. applicationType=$($conn.Hello.applicationType)"

Write-Host "[4/6] Locating Main Process console actor..."
$consoleActor = Get-MainProcessConsoleActor -Conn $conn
Write-Host "      Console actor: $consoleActor"

Write-Host "[5/6] Loading backup/restore payload and running backup..."
$payload = Get-Content (Join-Path $PSScriptRoot "fab_rdp_payload.js") -Raw
Invoke-RdpEval -Conn $conn -ConsoleActor $consoleActor -Text $payload | Out-Null
$log = Invoke-RdpEval -Conn $conn -ConsoleActor $consoleActor -Text "fab_backup_create_v2($FabPort)" -TimeoutSec 600
Write-Host "      Device-side log:"
Write-Host $log

Write-Host "[6/6] Waiting for transfer to finish..."
Wait-Job $job -Timeout 120 | Out-Null
Receive-Job $job
Remove-Job $job -Force

Close-RdpConnection -Conn $conn

if (Test-Path $absOutFile) {
    $size = (Get-Item $absOutFile).Length
    Write-Host ""
    Write-Host "SUCCESS: Backup saved to $absOutFile ($size bytes)"
} else {
    Write-Host ""
    Write-Host "FAILED: output file was not created"
    exit 1
}
