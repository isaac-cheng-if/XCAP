@echo off
rem Run as administrator on the PC that holds both the card and the JTAG cable. No reboot.
rem After the HDMI evaluation core has timed out, or after a warm reboot that lost the card.
for /f "tokens=3" %%i in ('pnputil /enum-devices /connected /bus PCI ^| findstr /c:"VEN_10EE"') do pnputil /remove-device "%%i"
cd /d C:\dev\xcap
call C:\AMDDesignTools\2026.2\Vivado\bin\vivado.bat -mode batch -nojournal -nolog -source C:\dev\xcap\build\program.tcl -tclargs C:/dev/xcap/xcap_hdmi_rk_fh1159.bit
timeout /t 3 >nul
pnputil /scan-devices
timeout /t 2 >nul
C:\dev\veyra-xcap\xcap_test.exe hdmi
pause
