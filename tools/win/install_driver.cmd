@echo off
rem Run as administrator, after Secure Boot is off, "bcdedit /set testsigning on" has been set and the PC was restarted.
cd /d %~dp0driver
pnputil /add-driver xcap.inf /install
..\xcap_test.exe info
pause
