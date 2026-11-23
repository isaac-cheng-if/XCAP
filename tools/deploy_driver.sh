#!/bin/bash
# build + sign on vivado-win, copy the package to pcie-win:C:\xcap   usage: deploy_driver.sh 1.0.0.N
set -e
cd "$(dirname "$0")/.."
scp -q driver/*.c driver/*.inf driver/*.bat vivado-win:C:/dev/xcap/driver/
scp -q common/*.h vivado-win:C:/dev/xcap/common/
scp -q host/*.cpp host/*.h host/*.bat vivado-win:C:/dev/xcap/host/
ssh vivado-win 'set VSLANG=1033&& C:\dev\xcap\driver\build.bat && C:\dev\xcap\driver\sign.bat '"$1"' && C:\dev\xcap\host\build.bat' 2>&1 | iconv -f GBK -t UTF-8 -c | grep -E "error|OK|Errors|warning" || true
T=$(mktemp -d); scp -q 'vivado-win:C:/dev/xcap/driver/out/pkg/*' "$T/"; scp -q 'vivado-win:C:/dev/xcap/host/out/xcap_test.exe' "$T/"
scp -q "$T"/* pcie-win:C:/xcap/; rm -r "$T"; echo deployed
