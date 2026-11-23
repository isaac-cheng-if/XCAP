@echo off
setlocal
set /p PW=<C:\dev\xcap\sign\pw
set B=C:\dev\wdk\microsoft.windows.sdk.cpp\c\bin\10.0.26100.0\x64
set W=C:\dev\wdk\microsoft.windows.wdk.x64\c
cd /d C:\dev\xcap\driver\out
if exist pkg rmdir /s /q pkg
mkdir pkg
copy /y xcap.sys pkg\ >nul & copy /y xcap.inf pkg\ >nul
"%W%\bin\10.0.26100.0\x64\stampinf.exe" -f pkg\xcap.inf -d * -v %1 -a amd64 || exit /b 1
"%W%\tools\10.0.26100.0\x64\infverif.exe" /w /v pkg\xcap.inf
"%B%\signtool.exe" sign /q /fd SHA256 /f C:\dev\xcap\sign\xcap_test.pfx /p %PW% pkg\xcap.sys || exit /b 1
"%W%\bin\10.0.26100.0\x86\Inf2Cat.exe" /driver:pkg /os:10_X64,10_VB_X64,10_CO_X64,10_NI_X64,10_GE_X64 /uselocaltime || exit /b 1
"%B%\signtool.exe" sign /q /fd SHA256 /f C:\dev\xcap\sign\xcap_test.pfx /p %PW% pkg\xcap.cat || exit /b 1
copy /y C:\dev\xcap\sign\xcap_test.cer pkg\ >nul
dir /b pkg
echo SIGN OK
