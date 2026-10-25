# Anitero - local server (Windows PowerShell 5.1+)
# Serves index.html and reads/writes songs.csv in this folder. Localhost only.
# -Hidden: started without a console window (start.vbs). Errors are shown in a message box, and the server stops
# by itself when the app window is closed.
param([int]$Port = 8765, [switch]$Hidden)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$sep = [System.IO.Path]::DirectorySeparatorChar
$rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd($sep) + $sep
$dbPath  = Join-Path $root 'songs.csv'
$setPath = Join-Path $root 'setlist.json'
$utf8Bom    = New-Object System.Text.UTF8Encoding($true)
$utf8NoBom  = New-Object System.Text.UTF8Encoding($false)
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$backedUp = $false

function Read-Text([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return '' }
  $bytes = [System.IO.File]::ReadAllBytes($path)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
  }
  try { return $utf8Strict.GetString($bytes) }
  catch { return [System.Text.Encoding]::GetEncoding(932).GetString($bytes) }   # Excel "CSV" (Shift_JIS)
}

function Read-Body($req) {
  $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
  try { return $sr.ReadToEnd() } finally { $sr.Close() }
}

function Send-Bytes($res, [byte[]]$bytes, [string]$type, [int]$status = 200) {
  $res.StatusCode = $status
  $res.ContentType = $type
  $res.Headers.Add('Cache-Control', 'no-store')
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Send-Text($res, [string]$text, [string]$type = 'text/plain; charset=utf-8', [int]$status = 200) {
  Send-Bytes $res ($utf8NoBom.GetBytes($text)) $type $status
}

# Japanese text is written as \u escapes so this file stays plain ASCII (Windows PowerShell 5.1 reads it as ANSI)
function J([string]$s) { [regex]::Unescape($s) }
function Fail([string]$msg) {
  if ($Hidden) {
    try { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show($msg, (J '\u3042\u306b\u3066\u308d')) } catch {}
  } else { Write-Host $msg; Read-Host 'Press Enter to close' }
  exit 1
}
function Open-App([string]$u) {
  try {
    $edge = @(${env:ProgramFiles(x86)}, $env:ProgramFiles) | Where-Object { $_ } |
      ForEach-Object { Join-Path $_ 'Microsoft\Edge\Application\msedge.exe' } |
      Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($edge) { Start-Process -FilePath $edge -ArgumentList "--app=$u" } else { Start-Process $u }
  } catch { Write-Host "  Open $u in your browser." }
}

# Is Anitero already answering on this port? (quick: no proxy lookup, short timeout)
function Test-Anitero([int]$p) {
  try {
    $rq = [System.Net.HttpWebRequest]::Create("http://localhost:$p/api/ping")
    $rq.Proxy = $null; $rq.Timeout = 700; $rq.ReadWriteTimeout = 700
    $rs = $rq.GetResponse()
    try { $sr = New-Object System.IO.StreamReader($rs.GetResponseStream()); return ($sr.ReadToEnd() -eq 'anitero') } finally { $rs.Close() }
  } catch { return $false }
}

$mime = @{
  '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
  '.json' = 'application/json; charset=utf-8'; '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.svg' = 'image/svg+xml'
  '.woff2' = 'font/woff2'; '.woff' = 'font/woff'; '.ttf' = 'font/ttf'; '.otf' = 'font/otf'
}

# Find a free port
$listener = $null
# Try to open the port first (instant when it is free). Only when it is taken, check whether that is Anitero
# already running (started again from the shortcut): then just open another app window and finish.
for ($p = $Port; $p -lt $Port + 20; $p++) {
  $l = New-Object System.Net.HttpListener
  $l.Prefixes.Add("http://localhost:$p/")
  try { $l.Start(); $listener = $l; $Port = $p; break } catch { $l.Close() }
  if (Test-Anitero $p) { Open-App "http://localhost:$p/"; exit 0 }
}
if (-not $listener) {
  Fail ((J '\u8d77\u52d5\u3067\u304d\u307e\u305b\u3093\u3067\u3057\u305f\u3002\u307b\u304b\u306e\u30a2\u30d7\u30ea\u3092\u9589\u3058\u3066\u304b\u3089\u3001\u3082\u3046\u4e00\u5ea6\u8d77\u52d5\u3057\u3066\u304f\u3060\u3055\u3044\u3002') + "`n(port 8765-8784)")
}

$url = "http://localhost:$Port/"
try { $host.UI.RawUI.WindowTitle = "Anitero - $url" } catch {}
Write-Host ''
Write-Host "  Anitero is running:  $url"
Write-Host '  Songs are saved to songs.csv in this folder.'
Write-Host '  Keep this window open while you use the app. Close it to stop.'
Write-Host '  (It also stops by itself a few seconds after the app window is closed.)'
Write-Host ''

Open-App $url

# Stop by itself when the app is closed: the app pings every 15 s and sends "quit" when its window closes.
# A reload sends quit too, but its new requests arrive within a few seconds and cancel it.
$started  = Get-Date
$lastSeen = $null
$quitAt   = $null
$pending  = $null
while ($listener.IsListening) {
  if (-not $pending) { $pending = $listener.BeginGetContext($null, $null) }
  if (-not $pending.AsyncWaitHandle.WaitOne(1000)) {
    $now = Get-Date
    if ($quitAt -and ($now - $quitAt).TotalSeconds -gt 6 -and $lastSeen -le $quitAt) { break }
    if ($lastSeen -and ($now - $lastSeen).TotalSeconds -gt 180) { break }
    if (-not $lastSeen -and ($now - $started).TotalMinutes -gt 10) { break }   # the app never opened
    continue
  }
  try { $ctx = $listener.EndGetContext($pending) } catch { break } finally { $pending = $null }
  $lastSeen = Get-Date
  $req = $ctx.Request
  $res = $ctx.Response
  try {
    $path = [System.Uri]::UnescapeDataString($req.Url.AbsolutePath)
    $method = $req.HttpMethod

    if ($path -eq '/api/ping') { Send-Text $res 'anitero' }
    elseif ($path -eq '/api/quit') { $quitAt = Get-Date; Send-Text $res 'ok' }
    elseif ($path -eq '/api/db') {
      if ($method -eq 'GET') { Send-Text $res (Read-Text $dbPath) }
      elseif ($method -eq 'PUT') {
        $body = Read-Body $req
        if (-not $backedUp -and (Test-Path -LiteralPath $dbPath)) {
          Copy-Item -LiteralPath $dbPath -Destination (Join-Path $root 'songs.backup.csv') -Force
          $backedUp = $true
        }
        [System.IO.File]::WriteAllText($dbPath, $body, $utf8Bom)   # UTF-8 with BOM opens cleanly in Excel
        Send-Text $res 'ok'
      }
      else { Send-Text $res 'method not allowed' 'text/plain' 405 }
    }
    elseif ($path -eq '/api/backup') {
      if ($method -eq 'POST') {
        if (Test-Path -LiteralPath $dbPath) {
          $bdir = Join-Path $root 'backup'
          if (-not (Test-Path -LiteralPath $bdir)) { New-Item -ItemType Directory -Path $bdir | Out-Null }
          $name = 'songs_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.csv'
          Copy-Item -LiteralPath $dbPath -Destination (Join-Path $bdir $name) -Force
          # keep the newest 30 backups
          Get-ChildItem -LiteralPath $bdir -Filter 'songs_*.csv' | Sort-Object Name -Descending |
            Select-Object -Skip 30 | Remove-Item -Force -ErrorAction SilentlyContinue
        }
        Send-Text $res 'ok'
      }
      else { Send-Text $res 'method not allowed' 'text/plain' 405 }
    }
    elseif ($path -eq '/api/notice') {
      $noticePath = Join-Path $root 'notice.json'
      if ($method -eq 'GET') { Send-Text $res (Read-Text $noticePath) 'application/json; charset=utf-8' }
      elseif ($method -eq 'PUT') { [System.IO.File]::WriteAllText($noticePath, (Read-Body $req), $utf8NoBom); Send-Text $res 'ok' }
      else { Send-Text $res 'method not allowed' 'text/plain' 405 }
    }
    elseif ($path -eq '/api/history') {
      $histPath = Join-Path $root 'history.json'
      if ($method -eq 'GET') { $t = Read-Text $histPath; if (-not $t) { $t = '[]' }; Send-Text $res $t 'application/json; charset=utf-8' }
      elseif ($method -eq 'PUT') { [System.IO.File]::WriteAllText($histPath, (Read-Body $req), $utf8NoBom); Send-Text $res 'ok' }
      else { Send-Text $res 'method not allowed' 'text/plain' 405 }
    }
    elseif ($path -eq '/api/setlist') {
      if ($method -eq 'GET') { $t = Read-Text $setPath; if (-not $t) { $t = '[]' }; Send-Text $res $t 'application/json; charset=utf-8' }
      elseif ($method -eq 'PUT') { [System.IO.File]::WriteAllText($setPath, (Read-Body $req), $utf8NoBom); Send-Text $res 'ok' }
      else { Send-Text $res 'method not allowed' 'text/plain' 405 }
    }
    else {
      if ($path -eq '/' -or $path -eq '') { $path = '/index.html' }
      $rel = $path.TrimStart('/').Replace('/', [string]$sep)
      $file = [System.IO.Path]::GetFullPath((Join-Path $root $rel))
      if (-not $file.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Send-Text $res 'forbidden' 'text/plain' 403
      }
      elseif (Test-Path -LiteralPath $file -PathType Leaf) {
        $ext = [System.IO.Path]::GetExtension($file).ToLower()
        $type = $mime[$ext]; if (-not $type) { $type = 'application/octet-stream' }
        Send-Bytes $res ([System.IO.File]::ReadAllBytes($file)) $type
      }
      else { Send-Text $res 'not found' 'text/plain' 404 }
    }
  }
  catch {
    Write-Host ('Error: ' + $_.Exception.Message)
    try { Send-Text $res 'error' 'text/plain' 500 } catch {}
  }
  finally { try { $res.Close() } catch {} }
}
try { $listener.Stop(); $listener.Close() } catch {}
