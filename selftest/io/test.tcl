proc wr {a d} { create_hw_axi_txn -quiet -force w [get_hw_axis hw_axi_1] -type write -address [format %08x $a] -data [format %08x [expr {$d & 0xffffffff}]] -len 1; run_hw_axi -quiet w }
proc rd {a} { create_hw_axi_txn -quiet -force r [get_hw_axis hw_axi_1] -type read -address [format %08x $a] -len 1; run_hw_axi -quiet r; return [expr "0x[get_property DATA [get_hw_axi_txns r]]"] }
set ::ctl 0
proc ctlset {mask v} { set ::ctl [expr {($::ctl & ~$mask) | ($v ? $mask : 0)}]; wr 0x004 $::ctl }
# serial engine: nbits<=64, data MSB-first left aligned in 64 bit
proc ser {tgt n hi lo oehi oelo {div 100}} {
  wr 0x044 $div; wr 0x04c $hi; wr 0x048 $lo; wr 0x054 $oehi; wr 0x050 $oelo
  wr 0x040 [expr {0x80000000 | ($tgt<<8) | $n}]
  for {set i 0} {$i<100} {incr i} { if {([rd 0x040]&1)==0} break }
  return [list [rd 0x05c] [rd 0x058]] }
proc qspi {cmdhi cmdlo n} { ctlset 0x10000 1; set r [ser 0 $n $cmdhi $cmdlo 0xffffffff 0xffffffff]; ctlset 0x10000 0; return $r }
proc mdio_rd {phy reg} {
  ser 2 32 0xffffffff 0 0xffffffff 0
  set hd [expr {(1<<14)|(2<<12)|($phy<<7)|($reg<<2)|0}]
  set r [ser 2 32 [expr {($hd<<16)|0xffff}] 0xffffffff 0xfffc0000 0]
  return [expr {[lindex $r 1] & 0xffff}] }
proc mdio_wr {phy reg v} {
  ser 2 32 0xffffffff 0 0xffffffff 0
  set hd [expr {(1<<14)|(1<<12)|($phy<<7)|($reg<<2)|2}]
  ser 2 32 [expr {($hd<<16)|($v&0xffff)}] 0xffffffff 0xffffffff 0 }
# i2c bit-bang; sh=0 EEPROM, sh=2 FMC. reg bit=1 -> drive low
proc i2c_set {sh scl sda} { wr 0x00c [expr {((!$scl)|((!$sda)<<1))<<$sh}] }
proc i2c_get {sh} { return [expr {([rd 0x00c]>>$sh)&3}] }
proc i2c_start {sh} { i2c_set $sh 1 1; i2c_set $sh 1 0; i2c_set $sh 0 0 }
proc i2c_stop {sh} { i2c_set $sh 0 0; i2c_set $sh 1 0; i2c_set $sh 1 1 }
proc i2c_w {sh b} { for {set i 7} {$i>=0} {incr i -1} { set d [expr {($b>>$i)&1}]; i2c_set $sh 0 $d; i2c_set $sh 1 $d; i2c_set $sh 0 $d }
  i2c_set $sh 0 1; i2c_set $sh 1 1; set a [expr {([i2c_get $sh]>>1)&1}]; i2c_set $sh 0 1; return [expr {!$a}] }
proc i2c_r {sh ack} { set v 0; for {set i 0} {$i<8} {incr i} { i2c_set $sh 0 1; i2c_set $sh 1 1; set v [expr {($v<<1)|(([i2c_get $sh]>>1)&1)}]; i2c_set $sh 0 1 }
  i2c_set $sh 0 [expr {!$ack}]; i2c_set $sh 1 [expr {!$ack}]; i2c_set $sh 0 1; return $v }
proc pins_in {} { set l {}; foreach a {0x140 0x144 0x148 0x14c 0x150} { lappend l [rd $a] }; return $l }
proc pin_bit {l i} { return [expr {([lindex $l [expr {$i/32}]]>>($i%32))&1}] }
proc setvec {base l} { for {set k 0} {$k<5} {incr k} { wr [expr {$base+4*$k}] [lindex $l $k] } }
