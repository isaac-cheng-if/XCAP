@echo off
rem New deployment directory from the previous one (runtime, data, scripts), with this build's program, QML, shaders and the Qt modules it needs.
setlocal
set SRC=C:\dev\veyra-xcap
set DST=C:\dev\veyra-xcap-221
set B=C:\dev\veyra221-full
if exist %DST% (echo %DST% exists & exit /b 1)
robocopy %SRC% %DST% /E /XD %SRC%\logs %SRC%\bak %SRC%\clip %SRC%\testaudio /NFL /NDL /NJH /NP
if errorlevel 8 exit /b 1
rmdir /s /q %DST%\qml\Veyra
robocopy %B%\qml\Veyra %DST%\qml\Veyra /E /NFL /NDL /NJH /NP
robocopy %B%\shaders %DST%\shaders *.dxil /S /NFL /NDL /NJH /NP
copy /y %B%\veyra_qml_ui.exe %DST%\ >nul || exit /b 1
copy /y %B%\veyra_xcap_probe.exe %DST%\ >nul
copy /y %B%\veyra_xcap_audio_tests.exe %DST%\ >nul
copy /y %B%\virtualcam\veyra-virtualcam64.dll %DST%\virtualcam\ >nul
copy /y %B%\virtualcam-x86\veyra-virtualcam32.dll %DST%\virtualcam\ >nul
copy /y %B%\virtualcam\veyra-camera-setup.exe %DST%\virtualcam\ >nul
C:\dev\Qt\6.8.3\msvc2022_64\bin\windeployqt.exe --release --qmldir C:\dev\veyra221\qml --no-compiler-runtime --no-translations --no-patchqt --no-opengl-sw --skip-plugin-types qmltooling,generic %DST%\veyra_qml_ui.exe > C:\dev\windeployqt221.log 2>&1 || (echo windeployqt failed & exit /b 1)
for %%f in (realplay.cmd Veyra_XCAP.cmd) do powershell -c "(Get-Content %DST%\%%f) -replace 'C:\\dev\\veyra-xcap\b','C:\dev\veyra-xcap-221' | Set-Content -Encoding ascii %DST%\%%f"
echo DEPLOY OK
