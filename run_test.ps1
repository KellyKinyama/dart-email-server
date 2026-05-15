$proc = Start-Process -FilePath dart -ArgumentList "run","examples\laravel_bridge.dart" -PassThru -RedirectStandardOutput bridge.out -RedirectStandardError bridge.err -NoNewWindow
Start-Sleep -Seconds 3
$log = New-Object System.Collections.Generic.List[string]
function L($s) { Write-Output $s; $log.Add($s) }
function Send-Smtp() {
  try {
    $tcp = New-Object System.Net.Sockets.TcpClient("127.0.0.1", 2525)
    $stream = $tcp.GetStream()
    $reader = New-Object System.IO.StreamReader($stream)
    $writer = New-Object System.IO.StreamWriter($stream)
    $writer.NewLine = "`r`n"; $writer.AutoFlush = $true
    Start-Sleep -Milliseconds 500
    while ($stream.DataAvailable) { L ("S: " + $reader.ReadLine()) }
    foreach ($line in @("EHLO test.local","MAIL FROM:<sender@example.com>","RCPT TO:<demo@example.com>","DATA")) {
      L ("C: " + $line); $writer.WriteLine($line); Start-Sleep -Milliseconds 500
      while ($stream.DataAvailable) { L ("S: " + $reader.ReadLine()) }
    }
    $body = "From: sender@example.com`r`nTo: demo@example.com`r`nSubject: Hello World`r`nMessage-ID: <abc@x>`r`nDate: Fri, 15 May 2026 10:00:00 +0000`r`n`r`nThis is the body.`r`n.`r`n"
    L "C: <body+terminator>"; $writer.Write($body); Start-Sleep -Milliseconds 800
    while ($stream.DataAvailable) { L ("S: " + $reader.ReadLine()) }
    L "C: QUIT"; $writer.WriteLine("QUIT"); Start-Sleep -Milliseconds 300
    while ($stream.DataAvailable) { L ("S: " + $reader.ReadLine()) }
    $tcp.Close()
  } catch { L "Error in SMTP: $_" }
}
function Invoke-Imap($cmds) {
  try {
    $tcp = New-Object System.Net.Sockets.TcpClient("127.0.0.1", 2143)
    $stream = $tcp.GetStream()
    $reader = New-Object System.IO.StreamReader($stream)
    $writer = New-Object System.IO.StreamWriter($stream)
    $writer.NewLine = "`r`n"; $writer.AutoFlush = $true
    Start-Sleep -Milliseconds 500
    while ($stream.DataAvailable) { L ("S: " + $reader.ReadLine()) }
    foreach ($c in $cmds) {
      L ("C: " + $c); $writer.WriteLine($c); Start-Sleep -Milliseconds 1200
      while ($stream.DataAvailable) { L ("S: " + $reader.ReadLine()) }
    }
    $tcp.Close()
  } catch { L "Error in IMAP: $_" }
}
L "==== SMTP ===="
Send-Smtp
L "==== IMAP ===="
Invoke-Imap @("a1 LOGIN demo@example.com demo","a2 SELECT INBOX","a3 UID SEARCH ALL","a4 UID FETCH 1:* (UID FLAGS RFC822.SIZE)","a5 UID FETCH 1 (BODY.PEEK[])","a6 LOGOUT")
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
L "===STDERR==="; Get-Content bridge.err -ErrorAction SilentlyContinue | ForEach-Object { L $_ }
L "===STDOUT==="; Get-Content bridge.out -ErrorAction SilentlyContinue | ForEach-Object { L $_ }
$log | Out-File final_run.txt -Encoding ASCII
