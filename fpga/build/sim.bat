@echo off
cd /d C:\dev\xcap\sim
call C:\AMDDesignTools\2026.2\Vivado\bin\xvlog.bat -sv ..\rtl\xcap_tpg.sv ..\rtl\xcap_pack.sv ..\rtl\xcap_framer.sv ..\rtl\xcap_regs.sv ..\rtl\xcap_audio.sv ..\rtl\xcap_core.sv ..\tb\tb_core.sv C:\AMDDesignTools\2026.2\Vivado\data\verilog\src\glbl.v || exit /b 1
call C:\AMDDesignTools\2026.2\Vivado\bin\xelab.bat -L xpm -L unisims_ver tb_core glbl -s tb || exit /b 1
call C:\AMDDesignTools\2026.2\Vivado\bin\xsim.bat tb -R
