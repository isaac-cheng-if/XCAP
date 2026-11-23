# Third-party sources in this folder

- `dp159.c`, `dp159.h` (SN65DP159 retimer) and `idt_8t49n24x.c`, `idt_8t49n24x.h` (IDT 8T49N24x clock chip) come from the AMD/Xilinx
  HDMI example designs (embeddedsw). dp159 carries `SPDX-License-Identifier: MIT`; current upstream versions of the IDT driver are MIT as well.
  Both were modified for XCAP (marked `xcap:` in comments): bounded I2C retries, LOS handling.
- `xparameters.h` is generated from the block design (`../bd.tcl`).
- The MicroBlaze BSP drivers (v_hdmirxss, v_hdmitxss, vphy, iic, ...) are not included; build.ps1 expects them in `bspx/` next to `fw/`.
