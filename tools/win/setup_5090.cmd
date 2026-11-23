@echo off
rem One-time setup of the XCAP card on this PC. Run as administrator, after:
rem   1. Secure Boot off in the BIOS        2. "bcdedit /set testsigning on" and a restart
rem The certificate and driver steps below change trust settings of this PC; read them before running.
setlocal
cd /d %~dp0
bcdedit /enum {current} | findstr /i "testsigning" | findstr /i "Yes" >nul || (echo Test signing is off: run "bcdedit /set testsigning on" and restart first. & pause & exit /b 1)
echo [1/4] trusting the XCAP test certificate (Root + TrustedPublisher)
certutil -addstore -f Root driver\xcap_test.cer >nul || goto fail
certutil -addstore -f TrustedPublisher driver\xcap_test.cer >nul || goto fail
echo [2/4] installing the driver
pnputil /add-driver driver\xcap.inf /install || goto fail
echo [3/4] card status
xcap_test.exe info
xcap_test.exe hdmi
echo [4/4] desktop shortcut for xcap_play
powershell -NoProfile -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Desktop')+'\PS5 补帧.lnk'); $s.TargetPath='%~dp0xcap_play.exe'; $s.WorkingDirectory='%~dp0'; $s.Save()"
echo done. If "xcap_test info" cannot open the card, the FPGA was not loaded when this PC started (QSPI not written yet).
pause
exit /b 0
:fail
echo failed, see above
pause
exit /b 1
