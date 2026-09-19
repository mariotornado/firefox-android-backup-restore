# Firefox Android DevTools RDP automation module.
# Speaks Firefox's Remote Debugging Protocol directly over a raw TCP socket
# (reached via `adb forward tcp:<port> localabstract:<pkg>/firefox-debugger-socket`)
# to evaluate privileged JS in Firefox's Main Process without any browser UI.

function New-RdpConnection {
    param([int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient("127.0.0.1", $Port)
    $stream = $client.GetStream()
    $stream.ReadTimeout = 30000
    $hello = Read-RdpPacket -Stream $stream
    return [PSCustomObject]@{
        Client = $client
        Stream = $stream
        Hello  = ($hello | ConvertFrom-Json)
    }
}

function Close-RdpConnection {
    param($Conn)
    $Conn.Client.Close()
}

function Send-RdpPacket {
    param($Stream, [hashtable]$Obj)
    $json = $Obj | ConvertTo-Json -Compress -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $header = [System.Text.Encoding]::UTF8.GetBytes("$($bytes.Length):")
    $Stream.Write($header, 0, $header.Length)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Read-RdpPacket {
    param($Stream)
    $lenStr = ""
    while ($true) {
        $b = $Stream.ReadByte()
        if ($b -eq -1) { throw "RDP connection closed while reading header" }
        $c = [char]$b
        if ($c -eq ':') { break }
        $lenStr += $c
    }
    $len = [int]$lenStr
    $buffer = New-Object byte[] $len
    $offset = 0
    while ($offset -lt $len) {
        $read = $Stream.Read($buffer, $offset, $len - $offset)
        if ($read -eq 0) { throw "RDP connection closed mid-body" }
        $offset += $read
    }
    return [System.Text.Encoding]::UTF8.GetString($buffer, 0, $len)
}

function Get-MainProcessConsoleActor {
    param($Conn)
    Send-RdpPacket -Stream $Conn.Stream -Obj @{ to = "root"; type = "listProcesses" }
    $resp = Read-RdpPacket -Stream $Conn.Stream | ConvertFrom-Json
    $mainProc = $resp.processes | Where-Object { $_.isParent -eq $true }
    if (-not $mainProc) { throw "Could not find Main Process (isParent=true) in listProcesses response" }

    Send-RdpPacket -Stream $Conn.Stream -Obj @{ to = $mainProc.actor; type = "getTarget" }
    $targetResp = Read-RdpPacket -Stream $Conn.Stream | ConvertFrom-Json
    if (-not $targetResp.process.consoleActor) { throw "getTarget response had no consoleActor" }
    return $targetResp.process.consoleActor
}

# Evaluates JS on the given console actor. Filters out unrelated unsolicited
# actor events (e.g. frameUpdate) that can arrive interleaved on the same connection.
# Throws on JS exceptions. Returns the evaluation result value.
function Invoke-RdpEval {
    param($Conn, [string]$ConsoleActor, [string]$Text, [int]$TimeoutSec = 300)

    # The socket-level read timeout must cover the whole eval, not just a
    # single packet gap, since a long-running device-side command (e.g. a
    # multi-hundred-MB tar stream) can legitimately take minutes between
    # packets arriving on this connection.
    $Conn.Stream.ReadTimeout = $TimeoutSec * 1000

    Send-RdpPacket -Stream $Conn.Stream -Obj @{ to = $ConsoleActor; type = "evaluateJSAsync"; text = $Text }

    $resultID = $null
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $raw = Read-RdpPacket -Stream $Conn.Stream
        $obj = $raw | ConvertFrom-Json
        if ($obj.from -ne $ConsoleActor) { continue }
        if (-not $resultID -and $obj.resultID -and -not $obj.type) {
            $resultID = $obj.resultID
            continue
        }
        if ($obj.type -eq "evaluationResult" -and $obj.resultID -eq $resultID) {
            if ($obj.hasException) {
                $msg = $obj.exceptionMessage
                if (-not $msg -and $obj.exception) { $msg = $obj.exception | ConvertTo-Json -Compress }
                throw "JS evaluation error: $msg"
            }
            return $obj.result
        }
    }
    throw "Timed out waiting for evaluationResult"
}

# Only valid when this file is loaded via Import-Module; when it's instead
# dot-sourced in-memory (as the compiled GUI exe does, to sidestep execution
# policy checks on the .psm1 file itself), there's no module context and
# this would throw, so it's a no-op in that case.
try {
    Export-ModuleMember -Function New-RdpConnection, Close-RdpConnection, Send-RdpPacket, Read-RdpPacket, Get-MainProcessConsoleActor, Invoke-RdpEval -ErrorAction Stop
} catch {}
