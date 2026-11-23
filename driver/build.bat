@echo off
setlocal
call C:\dev\VS\VC\Auxiliary\Build\vcvars64.bat >nul || exit /b 1
set W=C:\dev\wdk\microsoft.windows.wdk.x64\c
set S=C:\dev\wdk\microsoft.windows.sdk.cpp\c
set V=10.0.26100.0
set K=1.31
cd /d C:\dev\xcap\driver
if not exist out mkdir out
cl /nologo /c /Zi /W4 /WX /wd4324 /wd4201 /wd4214 /wd4152 /O2 /Oy- /GS /Gz /kernel /Zp8 /guard:cf /Qspectre ^
  /D_AMD64_ /DAMD64 /DWIN32_LEAN_AND_MEAN /DDEPRECATE_DDK_FUNCTIONS=1 /D_WIN32_WINNT=0x0A00 /DNTDDI_VERSION=0x0A00000B /DWINVER=0x0A00 /DKMDF_VERSION_MAJOR=1 /DKMDF_VERSION_MINOR=31 /DPOOL_NX_OPTIN=1 ^
  /I"%W%\Include\%V%\km" /I"%S%\Include\%V%\shared" /I"%W%\Include\%V%\shared" /I"%W%\Include\wdf\kmdf\%K%" /I..\common /Foout\ /Fdout\xcap.pdb xcap.c || exit /b 1
link /nologo /DRIVER /SUBSYSTEM:NATIVE,10.00 /ENTRY:FxDriverEntry /NODEFAULTLIB /INTEGRITYCHECK /guard:cf /DEBUG /PDB:out\xcap_link.pdb /OPT:REF /OPT:ICF /MERGE:_TEXT=.text /MERGE:_PAGE=PAGE /SECTION:INIT,d ^
  /RELEASE /NXCOMPAT /DYNAMICBASE /MANIFEST:NO /OUT:out\xcap.sys out\xcap.obj ^
  "%W%\Lib\%V%\km\x64\ntoskrnl.lib" "%W%\Lib\%V%\km\x64\hal.lib" "%W%\Lib\%V%\km\x64\wmilib.lib" "%W%\Lib\%V%\km\x64\BufferOverflowFastFailK.lib" "%W%\Lib\wdf\kmdf\x64\%K%\WdfDriverEntry.lib" "%W%\Lib\wdf\kmdf\x64\%K%\WdfLdr.lib" || exit /b 1
copy /y xcap.inf out\ >nul
echo BUILD OK
