# ============================================================================
#  report_all.tcl -- regenerate utilization + timing reports for the three
#                    AV2 loop-restoration Vivado projects.
#
#  WHY: the .runs directories are gitignored, so anyone who clones the repo
#  and wants the exact utilization / WNS numbers we quote in the README must
#  re-run implementation locally. This script does that for all three projects
#  and drops clean reports in ./reports/.
#
#  HOW TO RUN (Windows, from the repo root):
#
#     cd E:\ELIM_NonSeparable_V2_0\vivado\av2-loop-restoration-fpga
#     vivado -mode batch -source report_all.tcl -notrace
#
#  Runtime: expect 30-90 minutes total for all three (the combined RDO design
#  is the slow one). Reports land in ./reports/.
#
#  If you only need one, comment out the others in the PROJECTS list below.
# ============================================================================

set REPO   [file normalize [file dirname [info script]]]
set OUTDIR [file join $REPO reports]
file mkdir $OUTDIR

# {label  project_file  implementation_run  top_or_bd_wrapper}
set PROJECTS {
    {pc   pc/fpga_pc.xpr        impl_1  pc_filter_bd_wrapper}
    {ns   ns/fpga_ns.xpr        impl_1  ns_filter_bd_wrapper}
    {rdo  rdo/rdo_filter.xpr    impl_1  rdo_filter_bd_wrapper}
}

proc log_line {msg} {
    puts "############ $msg"
}

foreach entry $PROJECTS {
    lassign $entry label xpr implrun top

    set xprpath [file join $REPO $xpr]
    if {![file exists $xprpath]} {
        log_line "SKIP $label -- $xprpath not found"
        continue
    }

    log_line "OPEN $label ($xpr)"
    open_project $xprpath

    # --- synthesis ------------------------------------------------------
    if {[get_property NEEDS_REFRESH [get_runs synth_1]] || \
        [get_property PROGRESS [get_runs synth_1]] ne "100%"} {
        log_line "SYNTH $label"
        reset_run synth_1
        launch_runs synth_1 -jobs 8
        wait_on_run synth_1
    } else {
        log_line "SYNTH $label -- already up to date, reusing"
    }

    # --- implementation -------------------------------------------------
    log_line "IMPL $label"
    reset_run $implrun
    launch_runs $implrun -jobs 8
    wait_on_run $implrun

    if {[get_property PROGRESS [get_runs $implrun]] ne "100%"} {
        log_line "ERROR: implementation failed for $label -- see the run log"
        close_project
        continue
    }

    # --- reports --------------------------------------------------------
    open_run $implrun

    log_line "REPORT $label"

    report_utilization \
        -file [file join $OUTDIR ${label}_utilization.rpt]

    # Hierarchical view: shows which sub-module owns which resources.
    report_utilization -hierarchical -hierarchical_depth 3 \
        -file [file join $OUTDIR ${label}_utilization_hier.rpt]

    report_timing_summary -delay_type min_max -max_paths 10 \
        -report_unconstrained -significant_digits 3 \
        -file [file join $OUTDIR ${label}_timing.rpt]

    report_clocks -file [file join $OUTDIR ${label}_clocks.rpt]

    report_power  -file [file join $OUTDIR ${label}_power.rpt]

    # --- the four numbers the paper actually needs, printed to console ---
    set wns [get_property SLACK [get_timing_paths -delay_type max]]
    set whs [get_property SLACK [get_timing_paths -delay_type min]]

    puts "===================================================================="
    puts " $label  SUMMARY"
    puts "   WNS (setup slack) : $wns ns"
    puts "   WHS (hold slack)  : $whs ns"
    puts "   -> LUT/FF/BRAM/DSP percentages: see ${label}_utilization.rpt,"
    puts "      section 1. Slice Logic / 2. Memory / 3. DSP"
    puts "===================================================================="

    close_project
}

log_line "DONE -- reports written to $OUTDIR"
puts ""
puts "The five numbers the README quotes per configuration:"
puts "   LUT %, FF %, BRAM %, DSP %  (from *_utilization.rpt, 'Util%' column)"
puts "   WNS                          (from *_timing.rpt, 'Design Timing Summary')"
puts ""
