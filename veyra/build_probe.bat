@echo off
set VSLANG=1033
call C:\dev\VS\VC\Auxiliary\Build\vcvars64.bat >nul || exit /b 1
cd /d C:\dev\veyra
set CM=C:\dev\VS\Common7\IDE\CommonExtensions\Microsoft\CMake
set PATH=%CM%\CMake\bin;%CM%\Ninja;%PATH%
set D=C:/dev/veyra-deps
cmake -S . -B C:\dev\veyra-build -G Ninja -DCMAKE_BUILD_TYPE=Release -DVEYRA_ENABLE_D3D12_DEBUG=OFF -DVEYRA_FFMPEG_ROOT=%D%/ff -DVEYRA_ENABLE_DEINTERLACE=OFF -DVEYRA_ENABLE_LIBDOVI=OFF -DVEYRA_NVENC_HEADERS_ROOT=%D%/nv-codec-headers || exit /b 1
cmake --build C:\dev\veyra-build --target %* || exit /b 1
echo VEYRA OK
