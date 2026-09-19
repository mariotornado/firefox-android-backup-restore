param(
    [int]$Port = 12101,
    [string]$OutFile = "firefox-android-backup.tar.gz"
)
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "Listening on 127.0.0.1:$Port, writing to $OutFile ..."
$client = $listener.AcceptTcpClient()
Write-Host "Connection received, streaming to file..."
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
Write-Host "DONE. Received $total bytes, saved to $OutFile"
