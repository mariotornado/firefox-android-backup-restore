param(
    [int]$Port = 6100
)

function Send-RdpPacket {
    param($Stream, $Obj)
    $json = $Obj | ConvertTo-Json -Compress -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $header = [System.Text.Encoding]::UTF8.GetBytes("$($bytes.Length):")
    $Stream.Write($header, 0, $header.Length)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Read-RdpPacket {
    param($Stream)
    # Read the "<len>:" header byte by byte until colon
    $lenStr = ""
    while ($true) {
        $b = $Stream.ReadByte()
        if ($b -eq -1) { throw "Connection closed while reading header" }
        $c = [char]$b
        if ($c -eq ':') { break }
        $lenStr += $c
    }
    $len = [int]$lenStr
    $buffer = New-Object byte[] $len
    $offset = 0
    while ($offset -lt $len) {
        $read = $Stream.Read($buffer, $offset, $len - $offset)
        if ($read -eq 0) { throw "Connection closed mid-body" }
        $offset += $read
    }
    return [System.Text.Encoding]::UTF8.GetString($buffer, 0, $len)
}

$client = New-Object System.Net.Sockets.TcpClient("127.0.0.1", $Port)
$stream = $client.GetStream()
$stream.ReadTimeout = 10000

# Initial handshake packet from root actor
$hello = Read-RdpPacket -Stream $stream
Write-Host "HELLO: $hello"
Write-Host ""

# Ask root actor for list of processes
Send-RdpPacket -Stream $stream -Obj @{ to = "root"; type = "listProcesses" }
$resp = Read-RdpPacket -Stream $stream
Write-Host "listProcesses RESPONSE:"
Write-Host $resp
Write-Host ""

$procObj = $resp | ConvertFrom-Json
$mainProc = $procObj.processes | Where-Object { $_.isParent -eq $true }
$mainProcActor = $mainProc.actor
Write-Host "Main process descriptor actor: $mainProcActor"
Write-Host ""

Send-RdpPacket -Stream $stream -Obj @{ to = $mainProcActor; type = "getTarget" }
$targetResp = Read-RdpPacket -Stream $stream
Write-Host "getTarget RESPONSE:"
Write-Host $targetResp
Write-Host ""

$targetObj = $targetResp | ConvertFrom-Json
$consoleActor = $targetObj.process.consoleActor
Write-Host "Console actor: $consoleActor"
Write-Host ""

Send-RdpPacket -Stream $stream -Obj @{ to = $consoleActor; type = "evaluateJSAsync"; text = "typeof ChromeUtils" }

$resultID = $null
$finalResult = $null
for ($i = 0; $i -lt 20; $i++) {
    $raw = Read-RdpPacket -Stream $stream
    $obj = $raw | ConvertFrom-Json
    if ($obj.from -ne $consoleActor) { continue }
    if (-not $resultID -and $obj.resultID -and -not $obj.type) {
        $resultID = $obj.resultID
        Write-Host "Got ACK, resultID=$resultID"
        continue
    }
    if ($obj.type -eq "evaluationResult" -and $obj.resultID -eq $resultID) {
        $finalResult = $raw
        break
    }
}
Write-Host "FINAL evaluationResult:"
Write-Host $finalResult

$client.Close()
