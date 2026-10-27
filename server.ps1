# Effect&Telop VJ-System - local server (Windows PowerShell 5.1+)
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
    try { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show($msg, 'Effect&Telop VJ-System') } catch {}
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

# Is this app already answering on this port? (quick: no proxy lookup, short timeout)
function Test-Running([int]$p) {
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
  '.mp4' = 'video/mp4'; '.m4v' = 'video/mp4'; '.webm' = 'video/webm'
}

# ---------- effect videos ----------
# The video folder can be anywhere (for example an external SSD). It is kept in config.json; default: .\videos
# Videos for one song are named "<song title>_<number>.mp4"; general-purpose ones go in the sub folder "\u6c4e\u7528".
$cfgPath = Join-Path $root 'config.json'
$commonName = J '\u6c4e\u7528'
function Get-VideoDir {
  $d = ''
  try { $c = (Read-Text $cfgPath) | ConvertFrom-Json; if ($c.videoDir) { $d = [string]$c.videoDir } } catch {}
  if (-not $d) { $d = Join-Path $root 'videos'; if (-not (Test-Path -LiteralPath $d)) { try { New-Item -ItemType Directory -Path $d | Out-Null } catch {} } }
  return $d
}
function Save-VideoDir([string]$d) {
  [System.IO.File]::WriteAllText($cfgPath, '{"videoDir":' + (ConvertTo-Json $d) + '}', $utf8NoBom)
}
function Get-VideoList {
  $d = Get-VideoDir
  $ok = Test-Path -LiteralPath $d -PathType Container
  $songs = @(); $common = @()
  $ext = @('.mp4', '.m4v', '.webm')
  if ($ok) {
    $songs = @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Where-Object { $ext -contains $_.Extension.ToLower() } | Sort-Object Name |
      ForEach-Object { '{"f":' + (ConvertTo-Json $_.Name) + ',"t":' + $_.LastWriteTimeUtc.Ticks + '}' })
    $cd = Join-Path $d $commonName
    if (Test-Path -LiteralPath $cd -PathType Container) {
      $common = @(Get-ChildItem -LiteralPath $cd -File -ErrorAction SilentlyContinue | Where-Object { $ext -contains $_.Extension.ToLower() } | Sort-Object Name |
        ForEach-Object { '{"f":' + (ConvertTo-Json ($commonName + '/' + $_.Name)) + ',"t":' + $_.LastWriteTimeUtc.Ticks + '}' })
    }
  }
  return '{"dir":' + (ConvertTo-Json $d) + ',"ok":' + $ok.ToString().ToLower() + ',"common_folder":' + (ConvertTo-Json $commonName) +
    ',"songs":[' + ($songs -join ',') + '],"common":[' + ($common -join ',') + ']}'
}
# Windows folder picker, shown on top of the app window
function Pick-Folder([string]$start) {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  $f = New-Object System.Windows.Forms.Form
  $f.TopMost = $true; $f.ShowInTaskbar = $false; $f.StartPosition = 'CenterScreen'
  $f.Size = New-Object System.Drawing.Size(1, 1); $f.Opacity = 0
  $f.Show(); $f.Activate()
  $d = New-Object System.Windows.Forms.FolderBrowserDialog
  $d.Description = J '\u30a8\u30d5\u30a7\u30af\u30c8\u52d5\u753b\u306e\u30d5\u30a9\u30eb\u30c0\u3092\u9078\u3093\u3067\u304f\u3060\u3055\u3044'
  $d.ShowNewFolderButton = $false
  if ($start -and (Test-Path -LiteralPath $start)) { $d.SelectedPath = $start }
  try { if ($d.ShowDialog($f) -eq [System.Windows.Forms.DialogResult]::OK) { return $d.SelectedPath } else { return $null } }
  finally { $f.Close(); $d.Dispose() }
}
# Send a file in pieces (HTTP Range) so videos stream and seek without holding up the rest of the app
function Send-File($req, $res, [string]$file, [string]$type) {
  $fs = [System.IO.File]::Open($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $len = $fs.Length; $start = [int64]0; $end = $len - 1; $status = 200
    $rh = $req.Headers['Range']
    if ($rh -and $rh -match '^bytes=(\d*)-(\d*)$') {
      if ($matches[1] -ne '') { $start = [int64]$matches[1]; if ($matches[2] -ne '') { $end = [int64]$matches[2] } }
      elseif ($matches[2] -ne '') { $start = [Math]::Max([int64]0, $len - [int64]$matches[2]) }
      if ($start -ge $len) { $res.StatusCode = 416; $res.Headers.Add('Content-Range', "bytes */$len"); $res.ContentLength64 = 0; return }
      $end = [Math]::Min([Math]::Min($end, $len - 1), $start + 4MB - 1)
      $status = 206
    }
    $res.StatusCode = $status
    $res.ContentType = $type
    $res.Headers.Add('Accept-Ranges', 'bytes')
    $res.Headers.Add('Cache-Control', 'no-cache')
    if ($status -eq 206) { $res.Headers.Add('Content-Range', "bytes $start-$end/$len") }
    $n = $end - $start + 1
    $res.ContentLength64 = $n
    [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
    $buf = New-Object byte[] 262144
    while ($n -gt 0) {
      $r = $fs.Read($buf, 0, [int][Math]::Min($buf.Length, $n))
      if ($r -le 0) { break }
      $res.OutputStream.Write($buf, 0, $r)
      $n -= $r
    }
  } finally { $fs.Close() }
}

# Find a free port
$listener = $null
# Try to open the port first (instant when it is free). Only when it is taken, check whether that is this app
# already running (started again from the shortcut): then just open another app window and finish.
for ($p = $Port; $p -lt $Port + 20; $p++) {
  $l = New-Object System.Net.HttpListener
  $l.Prefixes.Add("http://localhost:$p/")
  try { $l.Start(); $listener = $l; $Port = $p; break } catch { $l.Close() }
  if (Test-Running $p) { Open-App "http://localhost:$p/"; exit 0 }
}
if (-not $listener) {
  Fail ((J '\u8d77\u52d5\u3067\u304d\u307e\u305b\u3093\u3067\u3057\u305f\u3002\u307b\u304b\u306e\u30a2\u30d7\u30ea\u3092\u9589\u3058\u3066\u304b\u3089\u3001\u3082\u3046\u4e00\u5ea6\u8d77\u52d5\u3057\u3066\u304f\u3060\u3055\u3044\u3002') + "`n(port 8765-8784)")
}

$url = "http://localhost:$Port/"
try { $host.UI.RawUI.WindowTitle = "Effect&Telop VJ-System - $url" } catch {}
Write-Host ''
Write-Host "  Effect&Telop VJ-System is running:  $url"
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
    elseif ($path -eq '/api/videos') { Send-Text $res (Get-VideoList) 'application/json; charset=utf-8' }
    elseif ($path -eq '/api/config') {
      if ($method -eq 'GET') { Send-Text $res ('{"videoDir":' + (ConvertTo-Json (Get-VideoDir)) + '}') 'application/json; charset=utf-8' }
      elseif ($method -eq 'PUT') {
        $d = ''
        try { $d = [string]((Read-Body $req) | ConvertFrom-Json).videoDir } catch {}
        Save-VideoDir $d.Trim()
        Send-Text $res (Get-VideoList) 'application/json; charset=utf-8'
      }
      else { Send-Text $res 'method not allowed' 'text/plain' 405 }
    }
    elseif ($path -eq '/api/pickdir') {
      $picked = $null
      try { $picked = Pick-Folder (Get-VideoDir) } catch { Write-Host ('Folder picker: ' + $_.Exception.Message) }
      if ($picked) { Save-VideoDir $picked; Send-Text $res (Get-VideoList) 'application/json; charset=utf-8' }
      else { Send-Text $res '{"cancel":true}' 'application/json; charset=utf-8' }
    }
    elseif ($path.StartsWith('/video/')) {
      $vd = [System.IO.Path]::GetFullPath((Get-VideoDir)).TrimEnd($sep) + $sep
      $vf = [System.IO.Path]::GetFullPath((Join-Path $vd ($path.Substring(7).Replace('/', [string]$sep))))
      if (-not $vf.StartsWith($vd, [System.StringComparison]::OrdinalIgnoreCase)) { Send-Text $res 'forbidden' 'text/plain' 403 }
      elseif (-not (Test-Path -LiteralPath $vf -PathType Leaf)) { Send-Text $res 'not found' 'text/plain' 404 }
      else {
        $vt = $mime[[System.IO.Path]::GetExtension($vf).ToLower()]; if (-not $vt) { $vt = 'application/octet-stream' }
        Send-File $req $res $vf $vt
      }
    }
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
