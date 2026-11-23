# QSPI (MT25QU256, x4)   -tclargs backup <file.bin>        reads the whole flash, changes nothing on it
#                        -tclargs write  <file.bit>        erases and programs: only after a backup
set w C:/dev/xcap
set op [lindex $argv 0]; set f [lindex $argv 1]
open_hw_manager
connect_hw_server -quiet
open_hw_target -quiet
set_property PARAM.FREQUENCY 10000000 [current_hw_target]
set dev [lindex [get_hw_devices xcau15p*] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts {mt25qu256-spi-x1_x2_x4}] 0]
set m [current_hw_cfgmem]
set_property PROGRAM.ADDRESS_RANGE {use_file} $m
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $m
foreach {k v} {PROGRAM.BLANK_CHECK 0 PROGRAM.ERASE 1 PROGRAM.CFG_PROGRAM 1 PROGRAM.VERIFY 1 PROGRAM.CHECKSUM 0} { set_property $k $v $m }
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev
if {$op eq "backup"} {
  readback_hw_cfgmem -force -all -format BIN -file $f -hw_cfgmem $m
} elseif {$op eq "write"} {
  write_cfgmem -force -format mcs -size 32 -interface SPIx4 -loadbit "up 0x00000000 $f" -file $w/xcap_qspi.mcs
  set_property PROGRAM.FILES [list $w/xcap_qspi.mcs] $m
  program_hw_cfgmem -hw_cfgmem $m
}
puts ALLDONE
