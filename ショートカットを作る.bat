@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=(Get-Location).Path; $n=Split-Path $d -Leaf; $ws=New-Object -ComObject WScript.Shell; foreach($p in @([Environment]::GetFolderPath('Desktop'), $d)){ $s=$ws.CreateShortcut((Join-Path $p ($n + '.lnk'))); $s.TargetPath=(Join-Path $d 'Effect&Telop VJ-System.vbs'); $s.WorkingDirectory=$d; $s.IconLocation=(Join-Path $d 'icon.ico') + ',0'; $s.Save() }; Write-Host ''; Write-Host '  Done. A shortcut with the icon was made on the Desktop and in this folder.'; Write-Host ''"
pause
