#!/bin/bash
# What the receiver really gets: plays MAT, E-AC-3, AC-3 and PCM from the 5090 PC (simulated card, very quiet tone) and asks the
# Yamaha receiver over the network. The G5 decodes Dolby and sends MAT/PCM on, so only the Atmos line must say Dolby Atmos; plain 5.1 shows PCM.
# Read only for the receiver.     usage: avr_check.sh [receiver ip]
AVR=${1:-${AVR_IP:?usage: avr_check.sh <receiver ip>  (or set AVR_IP)}}; B=http://$AVR/YamahaExtendedControl/v1
sig() { curl -s -m 3 $B/main/getSignalInfo | python3 -c "import sys,json;d=json.load(sys.stdin)['audio'];print(d['format'],d['fs'],d.get('bitrate') or '')" 2>/dev/null || echo "no answer"; }
curl -s -m 4 $B/main/getStatus | python3 -c "import sys,json;d=json.load(sys.stdin);print('receiver:',d['power'],'input',d['input_text'],'volume',d['actual_volume']['value'],'dB')"
run() {
  echo "lock=1 hdr=1 rate=59940 repeat=2 step=12 $2" | ssh vivado-win 'more > C:\dev\veyra-xcap\sim.txt'
  ssh vivado-win 'cd /d C:\dev\veyra-xcap && set XCAP_SIM=C:\dev\veyra-xcap\sim.txt&& veyra_xcap_probe.exe 11 hdmi sound' >/dev/null 2>&1 &
  local r=""; for i in 1 2 3 4; do sleep 2.7; r=$(sig); done; wait
  printf '%-34s -> %s\n' "$1" "$r"
}
run "Dolby Atmos in DD+ (passthrough)"   "audio=2 carrier=testaudio/atmos.eac3.raw crate=192000"
run "Dolby TrueHD in MAT (passthrough)" "audio=8 carrier=testaudio/a.mat.raw crate=192000"
run "Dolby Digital Plus (passthrough)"  "audio=2 carrier=testaudio/a.eac3.raw crate=192000"
run "Dolby Digital (passthrough)"       "audio=2 carrier=testaudio/a.ac3.raw crate=48000"
run "7.1 PCM through Windows"           "audio=8"
ssh vivado-win 'del C:\dev\veyra-xcap\sim.txt'
