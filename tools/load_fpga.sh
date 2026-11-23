#!/bin/bash
# disable the card, program the FPGA over JTAG, warm-reboot the test machine   usage: load_fpga.sh [file in C:\dev\xcap]
cd "$(dirname "$0")/.."
ID=$(ssh pcie-win 'pnputil /enum-devices /connected /bus PCI' | tr -d '\r' | awk '/Instance ID/&&/VEN_10EE/{print $3}')
[ -n "$ID" ] && ssh pcie-win "pnputil /disable-device \"$ID\"" | grep -i device
scp -q fpga/build/program.tcl vivado-win:C:/dev/xcap/build/
ssh vivado-win 'cd /d C:\dev\xcap && C:\AMDDesignTools\2026.2\Vivado\bin\vivado.bat -mode batch -nojournal -nolog -source C:\dev\xcap\build\program.tcl -tclargs C:/dev/xcap/'"${1:-xcap_hdmi_rk_fh1159.bit}"'' 2>&1 | grep -E "^DONE|^TCK|^ERROR"
ssh pcie-win 'shutdown /r /t 0'; sleep 60
for i in $(seq 1 20); do ssh -o ConnectTimeout=6 pcie-win 'echo up' 2>/dev/null && break; sleep 6; done
ID=$(ssh pcie-win 'pnputil /enum-devices /connected /bus PCI' | tr -d '\r' | awk '/Instance ID/&&/VEN_10EE/{print $3}'); echo "found $ID"
ssh pcie-win "pnputil /enable-device \"$ID\"" | grep -i -E "enabled|fail"
