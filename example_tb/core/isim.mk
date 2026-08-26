# ----------------------------------------------------------------------
# iSim (True North Silicon, https://tn-si.com) -- added as a native
# simulator target beside the vsim-* family the main Makefile already
# defines, the same place this Makefile already reserves per tool (its
# own variable prefix, its own target family). No separate vlib/vopt
# step: iSim's own work library covers create+analyse+elaborate in one
# binary, so this block is shorter than the ModelSim one above by
# design, not by omission.
#
# isim-run/isim-custom-run below are the first firmware run proven
# working against iSim for this core -- see ISIM_TASK_LIST.md. This is
# still the SIMPLE example_tb (tb_top + mm_ram), not core-v-verif's UVM
# environment (the isim.mk sibling in the
# Datum-Technology-Corporation/core-v-verif fork's mk/uvmt/, a separate,
# much larger frontier -- see the project's own rvmcu-vs-core-v-mcu
# distinction).
#
# iSim's `-f` command-file reader does not expand `${VAR}` tokens the
# way vsim's `-f` does -- a real, filed iSim CLI gap (True North
# Silicon github#... TODO once filed), not a cv32e40p quirk. So
# ISIM_MANIFEST/ISIM_FPU_MANIFEST translate cv32e40p_manifest.flist's
# and cv32e40p_fpu_manifest.flist's own ${DESIGN_RTL_DIR} tokens to the
# literal value the SAME env var already carries above, the one
# substitution vsim gets for free and iSim does not, yet.
# ----------------------------------------------------------------------
ISIM_VLOG		?= isim-vlog
ISIM_ELAB		?= isim-elab
ISIM			?= isim
ISIM_WORK		= isim_work
ISIM_MANIFEST		= .isim_cv32e40p_manifest.f
ISIM_FPU_MANIFEST	= .isim_cv32e40p_fpu_manifest.f
ISIM_TOP		= cv32e40p_top
ISIM_LOG_DIR		= isim_logs

# Every iSim tool shares one `-l <file>` flag (src/cli/isim_cli.c's
# isim_cli_report_opt, "one spelling for ten commands" -- present in
# every tool's own arg parsing even though it is missing from `-help`'s
# printed usage text today). It tees stdout AND stderr at the file
# descriptor level (fork+pipe, src/lib/isim_diag.c's isim_diag_log_open)
# straight into the named file while still printing live to the console
# -- so the command's own exit status reaches `make` untouched, no shell
# pipe, no pipefail needed.

$(ISIM_LOG_DIR):
	mkdir -p $(ISIM_LOG_DIR)

$(ISIM_MANIFEST): $(CV_CORE_MANIFEST)
	sed 's|$${DESIGN_RTL_DIR}|$(DESIGN_RTL_DIR)|g' $(CV_CORE_MANIFEST) > $(ISIM_MANIFEST)

$(ISIM_FPU_MANIFEST): $(RTLSRC_HOME)/cv32e40p_fpu_manifest.flist
	sed 's|$${DESIGN_RTL_DIR}|$(DESIGN_RTL_DIR)|g' $(RTLSRC_HOME)/cv32e40p_fpu_manifest.flist > $(ISIM_FPU_MANIFEST)

# Every isim-analyze* target starts from a CLEAN library. iSim's analyser
# refuses to re-declare a package that is already in the destination
# library (LRM-correct -- a second `isim-vlog` into the same -lib without
# clearing it first is not "add more files", it is "redeclare what's
# already there"), so a target that reused a stale $(ISIM_WORK) between
# runs would fail the SECOND time for a reason that has nothing to do
# with the design -- worse, only when a developer's own invocation order
# happened to leave one behind. Each target is therefore idempotent and
# order-independent on its own, at the cost of not being incremental.
ISIM_FRESH_WORK = rm -rf $(ISIM_WORK)

# Analyse the core RTL alone, upstream's own manifest, no testbench.
.PHONY: isim-analyze
isim-analyze: $(ISIM_MANIFEST) | $(ISIM_LOG_DIR)
	$(ISIM_FRESH_WORK)
	$(ISIM_VLOG) -l $(ISIM_LOG_DIR)/isim-analyze.log \
		-work $(ISIM_WORK) -lib work -f $(ISIM_MANIFEST)

# Analyse the FPU manifest variant (fpnew + the FP-enabled core).
.PHONY: isim-analyze-fp
isim-analyze-fp: $(ISIM_FPU_MANIFEST) | $(ISIM_LOG_DIR)
	$(ISIM_FRESH_WORK)
	$(ISIM_VLOG) -l $(ISIM_LOG_DIR)/isim-analyze-fp.log \
		-work $(ISIM_WORK) -lib work -f $(ISIM_FPU_MANIFEST)

# Analyse this example testbench's own sources on top of the core RTL --
# RTLSRC_TB_PKG/RTLSRC_TB are the main Makefile's own variables above,
# so a testbench file upstream adds is picked up here too.
.PHONY: isim-analyze-tb
isim-analyze-tb: $(ISIM_MANIFEST) | $(ISIM_LOG_DIR)
	$(ISIM_FRESH_WORK)
	$(ISIM_VLOG) -l $(ISIM_LOG_DIR)/isim-analyze-tb.log \
		-work $(ISIM_WORK) -lib work -f $(ISIM_MANIFEST) \
		$(RTLSRC_TB_PKG) $(RTLSRC_TB)

# Elaborate the assembled core as its own top -- no testbench. Useful on
# its own (isolates a core-only elaboration failure from a testbench-side
# one) but produces no image that can run: tb_top, not cv32e40p_top, is
# what owns the clock/reset generators, the memory and the
# pass/fail/exit signalling -- see isim-elab-tb below.
.PHONY: isim-elab
isim-elab: isim-analyze | $(ISIM_LOG_DIR)
	$(ISIM_ELAB) -l $(ISIM_LOG_DIR)/isim-elab.log \
		-work $(ISIM_WORK) -lib work -top $(ISIM_TOP) -sir

# Elaborate the FULL testbench (tb_top -> cv32e40p_tb_subsystem ->
# core + mm_ram/dp_ram) as top. `-sir` writes the native image
# ($(ISIM_WORK)/a.out.so) that isim-run below loads with `-image`;
# isim-elab-tb itself does not run it (isim-elab's own -help: "does not
# write an image" without -sir; WITH -sir it writes one but elaborating
# is still a separate step from running -- isim -image is what runs).
.PHONY: isim-elab-tb
isim-elab-tb: isim-analyze-tb | $(ISIM_LOG_DIR)
	$(ISIM_ELAB) -l $(ISIM_LOG_DIR)/isim-elab-tb.log \
		-work $(ISIM_WORK) -lib work -top tb_top -sir

# Run a firmware image against the elaborated testbench. tb_top.sv
# itself mandates a cycle timeout (mirroring riscv-tests' own
# convention, see mm_ram.sv's tb_timer comment) via +maxcycles -- without
# one, a design that never reaches tests_passed/tests_failed/exit_valid
# hangs forever instead of failing loud. ISIM_FIRMWARE/ISIM_RUN_FLAGS are
# meant to be set by a caller (see isim-custom-run below for the
# pattern, matching custom-vsim-run's own ALL_VSIM_FLAGS += idiom).
ISIM_MAXCYCLES		?= 200000
ISIM_RUN_FLAGS		?=

.PHONY: isim-run
isim-run: isim-elab-tb | $(ISIM_LOG_DIR)
	$(ISIM) -l $(ISIM_LOG_DIR)/isim-run.log \
		-image $(ISIM_WORK)/a.out.so \
		+firmware=$(ISIM_FIRMWARE) +maxcycles=$(ISIM_MAXCYCLES) $(ISIM_RUN_FLAGS)

# Run the 'Hello World' firmware -- the iSim analogue of custom-vsim-run.
.PHONY: isim-custom-run
isim-custom-run: custom/hello_world.hex
isim-custom-run: ISIM_FIRMWARE = custom/hello_world.hex
isim-custom-run: isim-run

.PHONY: isim-clean
isim-clean:
	rm -rf $(ISIM_WORK) $(ISIM_MANIFEST) $(ISIM_FPU_MANIFEST) $(ISIM_LOG_DIR)
