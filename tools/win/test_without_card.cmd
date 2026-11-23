@echo off
rem The whole chain on the TV with a simulated card: 4K60 HDR, 30 fps pictures, quiet 2-channel tone. Close Veyra to end.
cd /d %~dp0
echo lock=1 hdr=1 rate=59940 repeat=2 step=12 audio=2> sim.txt
set XCAP_SIM=%~dp0sim.txt
xcap_play.exe
