param(
    [string]$AdbPath = "C:\Users\Andrew\platform-tools-install\platform-tools\adb.exe",
    [string]$PackageId = "org.mozilla.firefox"
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if ($PSScriptRoot) {
    $ScriptDir = $PSScriptRoot
} else {
    # When compiled to a standalone .exe, $PSScriptRoot is not set; fall
    # back to the directory the .exe itself lives in, since the supporting
    # files (FirefoxRdp.psm1, fab_rdp_payload.js) are deployed alongside it.
    $ScriptDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}

# ---- Shared state between UI thread and background runspace ----
$sync = [hashtable]::Synchronized(@{
    LogQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    Busy     = $false
    Done     = $false
    Ok       = $false
})

function Get-DeviceList {
    $lines = & $AdbPath devices -l 2>$null
    $devices = @()
    foreach ($line in $lines) {
        if ($line -match '^(\S+)\s+device\s+.*model:(\S+)') {
            $devices += [PSCustomObject]@{ Serial = $matches[1]; Model = $matches[2]; Display = "$($matches[2])  ($($matches[1]))" }
        }
    }
    return $devices
}

# Diagnoses why a device isn't ready to use yet, so the setup wizard can show
# the right next step instead of a generic "no device found" dead end.
function Get-DeviceSetupStatus {
    param([string]$AdbPath, [string]$PackageId)

    $raw = & $AdbPath devices -l 2>$null
    $deviceLines = @($raw | Where-Object { $_ -match '^\S+\s+\S+' -and $_ -notmatch '^List of devices' })
    if ($deviceLines.Count -eq 0) {
        return [PSCustomObject]@{ Status = "NoDevice"; Serial = $null }
    }

    $parts = -split $deviceLines[0]
    $serial = $parts[0]
    $state = $parts[1]

    if ($state -eq "unauthorized") {
        return [PSCustomObject]@{ Status = "Unauthorized"; Serial = $serial }
    }
    if ($state -eq "offline") {
        return [PSCustomObject]@{ Status = "Offline"; Serial = $serial }
    }
    if ($state -ne "device") {
        return [PSCustomObject]@{ Status = "Unknown"; Serial = $serial }
    }

    $pkgCheck = & $AdbPath -s $serial shell pm list packages $PackageId 2>$null
    if (-not ($pkgCheck -match [regex]::Escape($PackageId))) {
        return [PSCustomObject]@{ Status = "FirefoxNotInstalled"; Serial = $serial }
    }

    $testPort = Get-Random -Minimum 7000 -Maximum 7999
    & $AdbPath -s $serial forward tcp:$testPort "localabstract:$PackageId/firefox-debugger-socket" 2>$null | Out-Null
    $reachable = $false
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $connectTask = $client.ConnectAsync("127.0.0.1", $testPort)
        if ($connectTask.Wait(2000) -and $client.Connected) {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 2000
            $buffer = New-Object byte[] 4096
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -gt 0) { $reachable = $true }
        }
        $client.Close()
    } catch {}
    & $AdbPath -s $serial forward --remove "tcp:$testPort" 2>$null | Out-Null

    if (-not $reachable) {
        return [PSCustomObject]@{ Status = "RemoteDebuggingOff"; Serial = $serial }
    }
    return [PSCustomObject]@{ Status = "Ready"; Serial = $serial }
}

$SetupInstructions = @{
    NoDevice = @"
STEP 1: Connect your phone and enable USB debugging

1. On the phone: Settings -> About phone -> tap "Build number" 7 times.
   You'll see a message that you're now a developer.
2. Settings -> System -> Developer options -> turn ON "USB debugging".
3. Plug the phone into this computer with a USB cable.
4. A popup should appear on the phone asking to allow USB debugging
   from this computer.

Waiting for a device to be detected...
"@
    Unauthorized = @"
STEP 1 (almost there): Authorize this computer

A device is connected but hasn't been authorized yet.

Look at your phone's screen right now - there should be a popup
asking "Allow USB debugging?". Check "Always allow from this
computer" and tap Allow.

If you don't see the popup, unplug and replug the USB cable.
"@
    Offline = @"
The device shows as "offline".

Try unplugging and replugging the USB cable, or unlocking the
phone's screen, then click Check Again.
"@
    FirefoxNotInstalled = @"
STEP 2: Install Firefox

Firefox isn't installed on this device yet.

Install it from the Play Store, open it once, then click Check Again.
"@
    RemoteDebuggingOff = @"
STEP 3: Enable Firefox's remote debugging

1. Open Firefox on the phone.
2. Tap the menu button (or your profile icon) -> Settings.
3. Scroll to the bottom -> tap "About Firefox".
4. Tap the Firefox logo/version number 5 times quickly.
   You'll see a message that you're now a developer.
5. Go back to Settings - a new "Remote debugging via USB" option
   should now appear near the bottom.
6. Turn it ON.
7. Click Check Again below.
"@
    Ready = @"
All set! This device is ready to use.

You can close this window and use Backup / Restore normally.
"@
    Unknown = @"
Unexpected device state. Try unplugging and replugging the USB cable,
then click Check Again.
"@
}

function Show-SetupWizard {
    param([string]$AdbPath, [string]$PackageId)

    $wiz = New-Object System.Windows.Forms.Form
    $wiz.Text = "Device Setup Help"
    $wiz.Size = New-Object System.Drawing.Size(540, 430)
    $wiz.StartPosition = "CenterParent"
    $wiz.FormBorderStyle = "FixedDialog"
    $wiz.MaximizeBox = $false

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15, 15)
    $lblStatus.Size = New-Object System.Drawing.Size(490, 26)
    $lblStatus.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $wiz.Controls.Add($lblStatus)

    $txtInstructions = New-Object System.Windows.Forms.TextBox
    $txtInstructions.Location = New-Object System.Drawing.Point(15, 50)
    $txtInstructions.Size = New-Object System.Drawing.Size(495, 280)
    $txtInstructions.Multiline = $true
    $txtInstructions.ReadOnly = $true
    $txtInstructions.ScrollBars = "Vertical"
    $txtInstructions.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $wiz.Controls.Add($txtInstructions)

    $btnCheck = New-Object System.Windows.Forms.Button
    $btnCheck.Text = "Check Again"
    $btnCheck.Location = New-Object System.Drawing.Point(15, 340)
    $btnCheck.Size = New-Object System.Drawing.Size(120, 30)
    $wiz.Controls.Add($btnCheck)

    $chkAuto = New-Object System.Windows.Forms.CheckBox
    $chkAuto.Text = "Check automatically every 2 seconds"
    $chkAuto.Location = New-Object System.Drawing.Point(150, 345)
    $chkAuto.Size = New-Object System.Drawing.Size(260, 24)
    $chkAuto.Checked = $true
    $wiz.Controls.Add($chkAuto)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(415, 340)
    $btnClose.Size = New-Object System.Drawing.Size(95, 30)
    $btnClose.DialogResult = "Cancel"
    $wiz.Controls.Add($btnClose)

    $doCheck = {
        $status = Get-DeviceSetupStatus -AdbPath $AdbPath -PackageId $PackageId
        $lblStatus.Text = "Status: $($status.Status)"
        $lblStatus.ForeColor = if ($status.Status -eq "Ready") { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::DarkOrange }
        $txtInstructions.Text = $SetupInstructions[$status.Status]
        if ($status.Status -eq "Ready") { $chkAuto.Checked = $false }
    }.GetNewClosure()

    $btnCheck.Add_Click($doCheck)

    $wizTimer = New-Object System.Windows.Forms.Timer
    $wizTimer.Interval = 2000
    $wizTimer.Add_Tick({ if ($chkAuto.Checked) { & $doCheck } }.GetNewClosure())
    $wizTimer.Start()

    $wiz.Add_Shown($doCheck)
    $wiz.Add_FormClosed({ $wizTimer.Stop(); $wizTimer.Dispose() })

    [void]$wiz.ShowDialog()
}

# ---- The actual backup/restore work, run inside a background runspace ----
$workerScriptBlock = {
    param($Sync, $AdbPath, $PackageId, $ScriptDir, $Mode, $DeviceSerial, $FilePath)

    function Log($msg) { $Sync.LogQueue.Enqueue($msg) }

    try {
        # Load the module's code in-memory rather than via Import-Module on
        # the .psm1 file path: Import-Module still enforces the system's
        # script execution policy for the file it loads, even when the
        # calling code is itself a compiled, policy-exempt .exe. Building a
        # scriptblock from the file's text and dot-sourcing it runs the same
        # code without ever going through that file-execution policy check.
        $moduleContent = Get-Content -Raw (Join-Path $ScriptDir "FirefoxRdp.psm1")
        . ([scriptblock]::Create($moduleContent))
        $adbArgs = @("-s", $DeviceSerial)
        $rdpPort = Get-Random -Minimum 6200 -Maximum 6999
        $payload = Get-Content (Join-Path $ScriptDir "fab_rdp_payload.js") -Raw

        if ($Mode -eq "Backup") {
            $fabPort = Get-Random -Minimum 13000 -Maximum 13999
            Log "Setting up adb forwards..."
            & $AdbPath @adbArgs forward tcp:$rdpPort "localabstract:$PackageId/firefox-debugger-socket" | Out-Null
            & $AdbPath @adbArgs reverse tcp:$fabPort tcp:$fabPort | Out-Null

            Log "Starting local listener for backup stream (separate process, so it can drain the socket concurrently)..."
            # Must run as a genuinely separate process, not just an async task
            # on this thread: the device-side "tar | nc" pipeline will only
            # finish once something actively reads the data as it arrives
            # (TCP flow control stalls the sender once OS buffers fill), and
            # this thread is about to block on Invoke-RdpEval until that
            # pipeline finishes. A separate job reads concurrently instead of
            # deadlocking against the blocking eval call.
            $listenerScript = {
                param($Port, $OutFile)
                $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
                $listener.Start()
                $client = $listener.AcceptTcpClient()
                $stream = $client.GetStream()
                $fileStream = [System.IO.File]::Create($OutFile)
                $buffer = New-Object byte[] 65536
                $total = 0
                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $fileStream.Write($buffer, 0, $read)
                    $total += $read
                }
                $fileStream.Close()
                $client.Close()
                $listener.Stop()
                $total
            }
            $listenerJob = Start-Job -ScriptBlock $listenerScript -ArgumentList $fabPort, $FilePath
            Start-Sleep -Milliseconds 500

            Log "Connecting to Firefox DevTools..."
            $conn = New-RdpConnection -Port $rdpPort
            Log "Connected (applicationType=$($conn.Hello.applicationType))"

            $consoleActor = Get-MainProcessConsoleActor -Conn $conn
            Log "Found Main Process console actor: $consoleActor"

            Invoke-RdpEval -Conn $conn -ConsoleActor $consoleActor -Text $payload | Out-Null

            Log "Requesting backup on device (this streams the profile over adb)..."
            $evalResult = Invoke-RdpEval -Conn $conn -ConsoleActor $consoleActor -Text "fab_backup_create_v2($fabPort)" -TimeoutSec 900
            Log "Device-side log:`n$evalResult"

            Wait-Job $listenerJob -Timeout 60 | Out-Null
            $total = Receive-Job $listenerJob
            Remove-Job $listenerJob -Force
            Log "Transfer complete: $total bytes written to $FilePath"

            Close-RdpConnection -Conn $conn
            $Sync.Ok = $true
        }
        elseif ($Mode -eq "Restore") {
            $remoteDir = "/sdcard/Android/data/$PackageId"
            $remoteFile = "$remoteDir/firefox-android-backup.tar.gz"

            Log "Pushing backup archive to device..."
            & $AdbPath @adbArgs shell mkdir -p $remoteDir | Out-Null
            & $AdbPath @adbArgs push $FilePath $remoteFile | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "adb push failed" }

            & $AdbPath @adbArgs forward tcp:$rdpPort "localabstract:$PackageId/firefox-debugger-socket" | Out-Null

            Log "Connecting to Firefox DevTools..."
            $conn = New-RdpConnection -Port $rdpPort
            Log "Connected (applicationType=$($conn.Hello.applicationType))"

            $consoleActor = Get-MainProcessConsoleActor -Conn $conn
            Log "Found Main Process console actor: $consoleActor"

            Invoke-RdpEval -Conn $conn -ConsoleActor $consoleActor -Text $payload | Out-Null

            Log "Applying restore on device..."
            $evalResult = Invoke-RdpEval -Conn $conn -ConsoleActor $consoleActor -Text "fab_backup_restore_apply_v2()" -TimeoutSec 300
            Log "Device-side log:`n$evalResult"

            Log "Restarting Firefox to complete restore..."
            try {
                Send-RdpPacket -Stream $conn.Stream -Obj @{ to = $consoleActor; type = "evaluateJSAsync"; text = "fab_kill_app()" }
                Start-Sleep -Milliseconds 500
            } catch {}
            try { Close-RdpConnection -Conn $conn } catch {}

            & $AdbPath @adbArgs shell rm -f "$remoteFile" "$remoteDir/firefox-android-backup.log" | Out-Null

            Log "Restore applied. Firefox was restarted on the device."
            $Sync.Ok = $true
        }
    } catch {
        Log "ERROR: $_"
        $Sync.Ok = $false
    } finally {
        $Sync.Busy = $false
        $Sync.Done = $true
    }
}

function Start-Worker {
    param($Mode, $DeviceSerial, $FilePath)

    $sync.Busy = $true
    $sync.Done = $false
    $sync.Ok = $false

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($workerScriptBlock).AddArgument($sync).AddArgument($AdbPath).AddArgument($PackageId).AddArgument($ScriptDir).AddArgument($Mode).AddArgument($DeviceSerial).AddArgument($FilePath)
    $handle = $ps.BeginInvoke()

    # Store for cleanup once done (checked by the UI timer)
    $script:activePs = $ps
    $script:activeHandle = $handle
    $script:activeRunspace = $runspace
}

# ---- Build the UI ----
$form = New-Object System.Windows.Forms.Form
$form.Text = "Firefox Android Transfer"
$form.Size = New-Object System.Drawing.Size(700, 520)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$lblDevice = New-Object System.Windows.Forms.Label
$lblDevice.Text = "Device:"
$lblDevice.Location = New-Object System.Drawing.Point(15, 18)
$lblDevice.Size = New-Object System.Drawing.Size(60, 20)
$form.Controls.Add($lblDevice)

$comboDevices = New-Object System.Windows.Forms.ComboBox
$comboDevices.Location = New-Object System.Drawing.Point(80, 15)
$comboDevices.Size = New-Object System.Drawing.Size(350, 24)
$comboDevices.DropDownStyle = "DropDownList"
$form.Controls.Add($comboDevices)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Refresh"
$btnRefresh.Location = New-Object System.Drawing.Point(440, 14)
$btnRefresh.Size = New-Object System.Drawing.Size(80, 26)
$form.Controls.Add($btnRefresh)

$btnSetupHelp = New-Object System.Windows.Forms.Button
$btnSetupHelp.Text = "Setup Help"
$btnSetupHelp.Location = New-Object System.Drawing.Point(525, 14)
$btnSetupHelp.Size = New-Object System.Drawing.Size(120, 26)
$form.Controls.Add($btnSetupHelp)

$btnBackup = New-Object System.Windows.Forms.Button
$btnBackup.Text = "Backup from device -> file"
$btnBackup.Location = New-Object System.Drawing.Point(15, 55)
$btnBackup.Size = New-Object System.Drawing.Size(310, 36)
$form.Controls.Add($btnBackup)

$btnRestore = New-Object System.Windows.Forms.Button
$btnRestore.Text = "Restore from file -> device"
$btnRestore.Location = New-Object System.Drawing.Point(335, 55)
$btnRestore.Size = New-Object System.Drawing.Size(310, 36)
$form.Controls.Add($btnRestore)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(15, 105)
$progress.Size = New-Object System.Drawing.Size(650, 20)
$progress.Style = "Marquee"
$progress.MarqueeAnimationSpeed = 0
$form.Controls.Add($progress)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(15, 135)
$txtLog.Size = New-Object System.Drawing.Size(650, 330)
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$form.Controls.Add($txtLog)

function Append-Log([string]$text) {
    $txtLog.AppendText("$text`r`n")
}

function Refresh-Devices {
    $comboDevices.Items.Clear()
    $devices = Get-DeviceList
    foreach ($d in $devices) {
        [void]$comboDevices.Items.Add($d)
    }
    $comboDevices.DisplayMember = "Display"
    if ($comboDevices.Items.Count -gt 0) { $comboDevices.SelectedIndex = 0 }
    Append-Log "Found $($devices.Count) device(s)."
}

function Set-Busy([bool]$busy) {
    $btnBackup.Enabled = -not $busy
    $btnRestore.Enabled = -not $busy
    $btnRefresh.Enabled = -not $busy
    $comboDevices.Enabled = -not $busy
    $progress.MarqueeAnimationSpeed = if ($busy) { 30 } else { 0 }
}

$btnRefresh.Add_Click({ Refresh-Devices })

$btnSetupHelp.Add_Click({
    Show-SetupWizard -AdbPath $AdbPath -PackageId $PackageId
    Refresh-Devices
})

$btnBackup.Add_Click({
    if ($comboDevices.SelectedItem -eq $null) {
        [System.Windows.Forms.MessageBox]::Show("No device selected.") | Out-Null
        return
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = "Firefox backup (*.tar.gz)|*.tar.gz"
    $dlg.FileName = "firefox-backup-$(Get-Date -Format yyyyMMdd-HHmmss).tar.gz"
    if ($dlg.ShowDialog() -ne "OK") { return }

    Set-Busy $true
    Append-Log "=== Starting backup from $($comboDevices.SelectedItem.Display) ==="
    Start-Worker -Mode "Backup" -DeviceSerial $comboDevices.SelectedItem.Serial -FilePath $dlg.FileName
})

$btnRestore.Add_Click({
    if ($comboDevices.SelectedItem -eq $null) {
        [System.Windows.Forms.MessageBox]::Show("No device selected.") | Out-Null
        return
    }
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "Firefox backup (*.tar.gz)|*.tar.gz"
    if ($dlg.ShowDialog() -ne "OK") { return }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "This will replace Firefox's data on $($comboDevices.SelectedItem.Display) with the contents of the selected backup, and force-close Firefox. Continue?",
        "Confirm restore", "YesNo", "Warning")
    if ($confirm -ne "Yes") { return }

    Set-Busy $true
    Append-Log "=== Starting restore to $($comboDevices.SelectedItem.Display) ==="
    Start-Worker -Mode "Restore" -DeviceSerial $comboDevices.SelectedItem.Serial -FilePath $dlg.FileName
})

# Timer drains the log queue and detects worker completion.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200
$timer.Add_Tick({
    $line = $null
    while ($sync.LogQueue.TryDequeue([ref]$line)) {
        Append-Log $line
    }
    if ($sync.Done) {
        Set-Busy $false
        Append-Log ($(if ($sync.Ok) { "=== SUCCESS ===" } else { "=== FAILED (see log above) ===" }))
        $sync.Done = $false
        if ($script:activePs) {
            $script:activePs.Dispose()
            $script:activeRunspace.Close()
            $script:activePs = $null
        }
    }
})
$timer.Start()

$form.Add_Shown({
    Refresh-Devices
    if ($comboDevices.Items.Count -eq 0) {
        Append-Log "No ready device found - opening setup help."
        Show-SetupWizard -AdbPath $AdbPath -PackageId $PackageId
        Refresh-Devices
    }
})
[void]$form.ShowDialog()
$timer.Stop()
