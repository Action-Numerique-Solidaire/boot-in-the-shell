@echo off
wpeinit
:connect
net use Z: \\192.168.0.102\win11 /user:guest "" /persistent:no
if errorlevel 1 (
  echo Le partage Windows 11 est indisponible. Nouvelle tentative dans 5 secondes.
  timeout /t 5
  goto connect
)
Z:\setup.exe
if errorlevel 1 cmd.exe
