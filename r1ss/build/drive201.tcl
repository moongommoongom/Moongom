cd C:/Users/Moon/Documents/r1ss
set q "C:/altera_lite/25.1std/quartus/bin64/quartus_sh.exe"
foreach v {ntsc_ss ntsc_sa1gsu} {
  set f [open "drive201_status.txt" a]; puts $f "START $v [clock format [clock seconds]]"; close $f
  catch {file delete -force src/fpga/output_files/ap_core.rbf}
  catch {exec $q -t generate.tcl $v > "drive201_$v.log" 2>@1}
  if {[file exists src/fpga/output_files/ap_core.rbf]} {
    file copy -force src/fpga/output_files/ap_core.rbf "out201_$v.rbf"
    set r OK
  } else { set r FAIL }
  foreach s [glob -nocomplain src/fpga/output_files/ap_core.sta.rpt] { catch {file copy -force $s "out201_$v.sta.rpt"} }
  foreach s [glob -nocomplain src/fpga/output_files/ap_core.fit.summary] { catch {file copy -force $s "out201_$v.fit.summary"} }
  foreach s [glob -nocomplain src/fpga/output_files/ap_core.map.rpt] { catch {file copy -force $s "out201_$v.map.rpt"} }
  set f [open "drive201_status.txt" a]; puts $f "END $v $r [clock format [clock seconds]]"; close $f
}
set f [open "drive201_status.txt" a]; puts $f "ALLDONE"; close $f
