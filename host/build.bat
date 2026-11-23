@echo off
call C:\dev\VS\VC\Auxiliary\Build\vcvars64.bat >nul || exit /b 1
cd /d C:\dev\xcap\host
if not exist out mkdir out
cl /nologo /std:c++20 /EHsc /O2 /W4 /wd4324 /MT /utf-8 /DNOMINMAX /I..\common /Foout\ /Feout\xcap_test.exe xcap_test.cpp xcap.cpp xcap_edid.cpp xcap_sim.cpp setupapi.lib || exit /b 1
cl /nologo /std:c++20 /EHsc /O2 /W4 /MT /utf-8 /DNOMINMAX /D_CRT_SECURE_NO_WARNINGS /Foout\ /Feout\xcap_play.exe xcap_play.cpp xcap.cpp xcap_edid.cpp xcap_sim.cpp setupapi.lib /I..\common /link /SUBSYSTEM:WINDOWS /ENTRY:wmainCRTStartup || exit /b 1
echo HOST OK
