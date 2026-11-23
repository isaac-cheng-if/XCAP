#!/bin/bash
# program the FPGA again and bring the card back WITHOUT rebooting   usage: reload_fpga.sh [bit in C:\dev\xcap] [host with the card]
cd "$(dirname "$0")/.."
BIT=${1:-xcap_hdmi_rk_fh1159.bit}; H=${2:-pcie-win}
id() { ssh $H 'pnputil /enum-devices /connected /bus PCI' | tr -d '\r' | awk '/Instance ID/&&/VEN_10EE/{print $3}'; }
ID=$(id); [ -n "$ID" ] && ssh $H "pnputil /remove-device \"$ID\"" | grep -iE "device|fail"
ssh vivado-win 'cd /d C:\dev\xcap && C:\AMDDesignTools\2026.2\Vivado\bin\vivado.bat -mode batch -nojournal -nolog -source C:\dev\xcap\build\program.tcl -tclargs C:/dev/xcap/'"$BIT"'' 2>&1 | grep -E "^DONE|^ERROR"
for i in 1 2 3 4 5; do sleep 2; ssh $H 'pnputil /scan-devices' >/dev/null; sleep 2; ID=$(id); [ -n "$ID" ] && break; done
[ -z "$ID" ] && { echo "card not back: reboot needed"; exit 1; }
echo "found $ID"; ssh $H "pnputil /enum-devices /instanceid \"$ID\"" | grep -iE "Status|Problem"
