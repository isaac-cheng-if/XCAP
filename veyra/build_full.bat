@echo off
set VSLANG=1033
chcp 65001 >nul
call C:\dev\VS\VC\Auxiliary\Build\vcvars64.bat >nul || exit /b 1
cd /d C:\dev\veyra
set CM=C:\dev\VS\Common7\IDE\CommonExtensions\Microsoft\CMake
set PATH=%CM%\CMake\bin;%CM%\Ninja;%PATH%
set D=C:/dev/veyra-deps
cmake -S . -B C:\dev\veyra-full -G Ninja -DCMAKE_BUILD_TYPE=Release -DVEYRA_ENABLE_D3D12_DEBUG=OFF -DVEYRA_ENABLE_EXPERIMENTAL_DLSSNR=ON -DVEYRA_DLSS_SDK_ROOT=%D%/dlss -DVEYRA_NVOF_SDK_ROOT=C:/Users/i/Documents/FPGA/Optical_Flow_SDK_5.0.7 -DVEYRA_CUDA_DRIVER_INCLUDE_DIR=%D%/cuda/include -DVEYRA_FFMPEG_ROOT=%D%/ff -DVEYRA_ENABLE_DEINTERLACE=OFF -DVEYRA_ENABLE_LIBDOVI=OFF -DVEYRA_NVENC_HEADERS_ROOT=%D%/nv-codec-headers -DVEYRA_BUILD_QML_UI=ON -DVEYRA_DISPLAY_VERSION=2.2.0-xcap-test -DCMAKE_PREFIX_PATH=C:/dev/Qt/6.8.3/msvc2022_64 -DOPENSSL_ROOT_DIR=%D%/vcpkg/installed/x64-windows || exit /b 1
cmake --build C:\dev\veyra-full --target %* || exit /b 1
echo VEYRA FULL OK
