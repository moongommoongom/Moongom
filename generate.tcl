# Run with quartus_sh -t generate.tcl

# Load Quartus II Tcl Project package
package require ::quartus::project

# Required for compilation
package require ::quartus::flow

if { $argc != 1 } {
  puts "Exactly 1 argument required"
  exit
}

project_open src/fpga/ap_core.qpf

# Savestates are off unless a *_ss variant turns them on (set_parameter is stored in the project)
set_parameter -name USE_SS -entity MAIN_SNES '0
set_parameter -name USE_SS -entity core_top '0
set_parameter -name SS_CHIP -entity MAIN_SNES '0
set_parameter -name NO_EXTRAS -entity MAIN_SNES '0

if { [lindex $argv 0] == "ntsc" } {
  puts "NTSC"
  set_parameter -name PAL_PLL -entity core_top '0

  set_parameter -name USE_CX4 -entity MAIN_SNES '1
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '1
  set_parameter -name USE_SA1 -entity MAIN_SNES '0
  set_parameter -name USE_DSPn -entity MAIN_SNES '1
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "pal" } {
  puts "PAL"
  set_parameter -name PAL_PLL -entity core_top '1

  set_parameter -name USE_CX4 -entity MAIN_SNES '1
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '1
  set_parameter -name USE_SA1 -entity MAIN_SNES '0
  set_parameter -name USE_DSPn -entity MAIN_SNES '1
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "ntsc_sdd1" } {
  puts "ntsc_sdd1"
  set_parameter -name PAL_PLL -entity core_top '0

  set_parameter -name USE_CX4 -entity MAIN_SNES '1
  set_parameter -name USE_SDD1 -entity MAIN_SNES '1
  set_parameter -name USE_GSU -entity MAIN_SNES '1
  set_parameter -name USE_SA1 -entity MAIN_SNES '0
  set_parameter -name USE_DSPn -entity MAIN_SNES '1
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "pal_sdd1" } {
  puts "pal_sdd1"
  set_parameter -name PAL_PLL -entity core_top '1

  set_parameter -name USE_CX4 -entity MAIN_SNES '1
  set_parameter -name USE_SDD1 -entity MAIN_SNES '1
  set_parameter -name USE_GSU -entity MAIN_SNES '1
  set_parameter -name USE_SA1 -entity MAIN_SNES '0
  set_parameter -name USE_DSPn -entity MAIN_SNES '1
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "ntsc_sa1gsu" } {
  puts "ntsc_sa1gsu"
  set_parameter -name PAL_PLL -entity core_top '0

  set_parameter -name USE_CX4 -entity MAIN_SNES '0
  set_parameter -name USE_SDD1 -entity MAIN_SNES '1
  set_parameter -name USE_GSU -entity MAIN_SNES '1
  set_parameter -name USE_SA1 -entity MAIN_SNES '1
  set_parameter -name USE_DSPn -entity MAIN_SNES '0
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "pal_sa1gsu" } {
  puts "pal_sa1gsu"
  set_parameter -name PAL_PLL -entity core_top '1

  set_parameter -name USE_CX4 -entity MAIN_SNES '0
  set_parameter -name USE_SDD1 -entity MAIN_SNES '1
  set_parameter -name USE_GSU -entity MAIN_SNES '1
  set_parameter -name USE_SA1 -entity MAIN_SNES '1
  set_parameter -name USE_DSPn -entity MAIN_SNES '0
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "ntsc_spc" } {
  puts "NTSC SPC"
  set_parameter -name PAL_PLL -entity core_top '0

  set_parameter -name USE_CX4 -entity MAIN_SNES '0
  set_parameter -name USE_SDD1 -entity MAIN_SNES '1
  set_parameter -name USE_GSU -entity MAIN_SNES '0
  set_parameter -name USE_SA1 -entity MAIN_SNES '0
  set_parameter -name USE_DSPn -entity MAIN_SNES '0
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '1
  set_parameter -name USE_BSX -entity MAIN_SNES '1
  set_parameter -name USE_MSU -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "ntsc_sa1" } {
  puts "NTSC SA1 MSU"
  set_parameter -name PAL_PLL -entity core_top '0

  set_parameter -name USE_CX4 -entity MAIN_SNES '0
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '0
  set_parameter -name USE_SA1 -entity MAIN_SNES '1
  set_parameter -name USE_DSPn -entity MAIN_SNES '0
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "none" } {
  puts "NONE"
  set_parameter -name PAL_PLL -entity core_top '0

  set_parameter -name USE_CX4 -entity MAIN_SNES '0
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '0
  set_parameter -name USE_SA1 -entity MAIN_SNES '0
  set_parameter -name USE_DSPn -entity MAIN_SNES '0
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '0
} elseif { [lindex $argv 0] == "none_pal" } {
  puts "NONE PAL"
  set_parameter -name PAL_PLL -entity core_top '1

  set_parameter -name USE_CX4 -entity MAIN_SNES '0
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '0
  set_parameter -name USE_SA1 -entity MAIN_SNES '0
  set_parameter -name USE_DSPn -entity MAIN_SNES '0
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '0
} elseif { [lindex $argv 0] == "ntsc_ss" } {
  puts "NTSC + savestates (R1 MSU-1, no coprocessors)"
  set_parameter -name PAL_PLL -entity core_top '0
  set_parameter -name USE_SS -entity core_top '1

  set_parameter -name USE_CX4 -entity MAIN_SNES '0
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '0
  set_parameter -name USE_SA1 -entity MAIN_SNES '0
  set_parameter -name USE_DSPn -entity MAIN_SNES '0
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
  set_parameter -name USE_SS -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "pal_ss" } {
  puts "0.8.5 PAL + savestates (no coprocessors)"
  set_parameter -name PAL_PLL -entity core_top '1
  set_parameter -name USE_SS -entity core_top '1

  set_parameter -name USE_CX4 -entity MAIN_SNES '0
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '0
  set_parameter -name USE_SA1 -entity MAIN_SNES '0
  set_parameter -name USE_DSPn -entity MAIN_SNES '0
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
  set_parameter -name USE_SS -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "v085_cx4dsp" } {
  puts "0.8.5 NTSC CX4 + DSP-n"
  set_parameter -name PAL_PLL -entity core_top '0

  set_parameter -name USE_CX4 -entity MAIN_SNES '1
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '0
  set_parameter -name USE_SA1 -entity MAIN_SNES '0
  set_parameter -name USE_DSPn -entity MAIN_SNES '1
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "v085_cx4dsp_pal" } {
  puts "0.8.5 PAL CX4 + DSP-n"
  set_parameter -name PAL_PLL -entity core_top '1

  set_parameter -name USE_CX4 -entity MAIN_SNES '1
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '0
  set_parameter -name USE_SA1 -entity MAIN_SNES '0
  set_parameter -name USE_DSPn -entity MAIN_SNES '1
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "v085_sa1gsu" } {
  puts "0.8.5 NTSC SA-1 + GSU"
  set_parameter -name PAL_PLL -entity core_top '0

  set_parameter -name USE_CX4 -entity MAIN_SNES '0
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '1
  set_parameter -name USE_SA1 -entity MAIN_SNES '1
  set_parameter -name USE_DSPn -entity MAIN_SNES '0
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "v085_sa1gsu_pal" } {
  puts "0.8.5 PAL SA-1 + GSU"
  set_parameter -name PAL_PLL -entity core_top '1

  set_parameter -name USE_CX4 -entity MAIN_SNES '0
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '1
  set_parameter -name USE_SA1 -entity MAIN_SNES '1
  set_parameter -name USE_DSPn -entity MAIN_SNES '0
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "ss_cx4dsp" } {
  puts "0.8.5 NTSC CX4 + DSP-n + savestates"
  set_parameter -name PAL_PLL -entity core_top '0
  set_parameter -name USE_SS -entity core_top '1

  set_parameter -name USE_CX4 -entity MAIN_SNES '1
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '0
  set_parameter -name USE_SA1 -entity MAIN_SNES '0
  set_parameter -name USE_DSPn -entity MAIN_SNES '1
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
  set_parameter -name USE_SS -entity MAIN_SNES '1
  set_parameter -name SS_CHIP -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "ss_cx4dsp_pal" } {
  puts "0.8.5 PAL CX4 + DSP-n + savestates"
  set_parameter -name PAL_PLL -entity core_top '1
  set_parameter -name USE_SS -entity core_top '1

  set_parameter -name USE_CX4 -entity MAIN_SNES '1
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '0
  set_parameter -name USE_SA1 -entity MAIN_SNES '0
  set_parameter -name USE_DSPn -entity MAIN_SNES '1
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
  set_parameter -name USE_SS -entity MAIN_SNES '1
  set_parameter -name SS_CHIP -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "ss_sa1" } {
  puts "0.8.5 NTSC SA-1 + savestates"
  set_parameter -name PAL_PLL -entity core_top '0
  set_parameter -name USE_SS -entity core_top '1

  set_parameter -name USE_CX4 -entity MAIN_SNES '0
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '0
  set_parameter -name USE_SA1 -entity MAIN_SNES '1
  set_parameter -name USE_DSPn -entity MAIN_SNES '0
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
  set_parameter -name USE_SS -entity MAIN_SNES '1
  set_parameter -name SS_CHIP -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "ss_sa1_pal" } {
  puts "0.8.5 PAL SA-1 + savestates"
  set_parameter -name PAL_PLL -entity core_top '1
  set_parameter -name USE_SS -entity core_top '1

  set_parameter -name USE_CX4 -entity MAIN_SNES '0
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '0
  set_parameter -name USE_SA1 -entity MAIN_SNES '1
  set_parameter -name USE_DSPn -entity MAIN_SNES '0
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
  set_parameter -name USE_SS -entity MAIN_SNES '1
  set_parameter -name SS_CHIP -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "ss_gsu" } {
  puts "0.8.5 NTSC Super FX + savestates"
  set_parameter -name PAL_PLL -entity core_top '0
  set_parameter -name USE_SS -entity core_top '1

  set_parameter -name USE_CX4 -entity MAIN_SNES '0
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '1
  set_parameter -name USE_SA1 -entity MAIN_SNES '0
  set_parameter -name USE_DSPn -entity MAIN_SNES '0
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
  set_parameter -name USE_SS -entity MAIN_SNES '1
  set_parameter -name SS_CHIP -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "ss_gsu_pal" } {
  puts "0.8.5 PAL Super FX + savestates"
  set_parameter -name PAL_PLL -entity core_top '1
  set_parameter -name USE_SS -entity core_top '1

  set_parameter -name USE_CX4 -entity MAIN_SNES '0
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '1
  set_parameter -name USE_SA1 -entity MAIN_SNES '0
  set_parameter -name USE_DSPn -entity MAIN_SNES '0
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
  set_parameter -name USE_SS -entity MAIN_SNES '1
  set_parameter -name SS_CHIP -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "ss_main" } {
  puts "0.8.5 NTSC main + S-DD1 + BS-X + savestates (voice stream, light gun)"
  set_parameter -name PAL_PLL -entity core_top '0
  set_parameter -name USE_SS -entity core_top '1

  set_parameter -name USE_CX4 -entity MAIN_SNES '0
  set_parameter -name USE_SDD1 -entity MAIN_SNES '1
  set_parameter -name USE_GSU -entity MAIN_SNES '0
  set_parameter -name USE_SA1 -entity MAIN_SNES '0
  set_parameter -name USE_DSPn -entity MAIN_SNES '0
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '1
  set_parameter -name USE_MSU -entity MAIN_SNES '1
  set_parameter -name USE_SS -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "v085_spc" } {
  puts "0.8.5 NTSC SPC7110 + savestates (experimental)"
  set_parameter -name PAL_PLL -entity core_top '0
  set_parameter -name USE_SS -entity core_top '1

  set_parameter -name USE_CX4 -entity MAIN_SNES '0
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '0
  set_parameter -name USE_SA1 -entity MAIN_SNES '0
  set_parameter -name USE_DSPn -entity MAIN_SNES '0
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '1
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
  set_parameter -name USE_SS -entity MAIN_SNES '1
  set_parameter -name SS_CHIP -entity MAIN_SNES '1
} else {
  puts "Unknown bitstream type [lindex $argv 0]"
  project_close
  exit
}

execute_flow -compile

project_close