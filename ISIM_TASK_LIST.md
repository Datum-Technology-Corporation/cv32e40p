# iSim integration task list — cv32e40p

Tracks what blocks `iSim` (True North Silicon) from cleanly compiling,
elaborating, and simulating this core and its example testbench, one item
at a time. Each item is a real, MEASURED observation against a specific
iSim build — never a guess — with enough evidence (file:line, exact
message) that it can be re-verified independently later. Status values:
`OPEN` (not yet investigated further), `INVESTIGATING`, `FILED` (an iSim
issue exists, link it), `FIXED` (cite the fix), `NOT-A-BUG` (investigated,
found benign or by-design, with the reasoning recorded).

See `example_tb/core/isim.mk` for the native `make isim-analyze` /
`isim-analyze-fp` / `isim-analyze-tb` / `isim-elab` targets and
`example_tb/core/isim_logs/` for their most recent run's captured output.

---

## 1. `riscv_rvalid_stall.sv:156` — structural array-port read has no lowering, core hangs after two fetches

**Status: FIXED — SW-514800 (iSim `1f86f7c78`, 2026-08-25). FIRST FULL
FIRMWARE RUN GREEN: `hello world!` / `EXIT SUCCESS` at time 22820,
cycle-exact with dsim 2026 (2282 SVA evaluations both). Minor residuals
noted below.**

**Where observed**: the first full firmware run (`make isim-run` with
`hello_world.hex`) hangs at the cycle limit with zero program output,
while dsim 2026 runs the identical sources+firmware to `hello world!` /
`EXIT SUCCESS` in 2282 cycles. Traced via `+ifetch_trace`: `instr_req`/
`instr_gnt` succeed twice (0x180, 0x184) then the pipeline waits forever
for an `instr_rvalid` that never arrives. Root cause is a build warning
present in every elaboration log:

```
warning: SIR: structural net driver 'lpm.array' has NO LOWERING
(array-port read) - the driven net NEVER UPDATES (silent-wrong; first
site riscv_rvalid_stall.sv:156; tgt_sir.cc:11390).
```

`assign current_delay = fifo[rptr[..]][FIFO_DELAY_LSB +: FIFO_DELAY_WL];`
— a continuous assign reading a part-select of a dynamically-indexed
unpacked-array word. With `current_delay` permanently X, the rvalid FIFO's
`!fifo_empty && current_delay == 0` never fires and `rvalid_o` stays 0.

**Fix**: SW-514800 in iSim — real structural lowering for
`ISIM_LPM_ARRAY` (the dynamic bound-checked SignalRead shape the
procedural lane already uses), plus a dsim-verified `sv_lrm` pile
regression pinning this exact FIFO shape
(`isim_sv_10_03_dynamic_array_word_continuous_assign`). Verified here:
`make isim-elab-tb` elaborates with `rejected-loud=0`, and
`make isim-custom-run` completes the hello_world firmware.

**Minor residuals observed on the green run (neither blocks anything):**

- iSim prints ten time-0 `unique case violation: no item matched`
  warnings (`cv32e40p_id_stage.sv`, `cv32e40p_load_store_unit.sv`)
  during reset X-propagation; dsim prints none for the same run. Needs
  an LRM 12.5 adjudication (is a unique-case with an X selector at
  time 0 reportable?) before calling either tool wrong.
- SVA summary accounting differs slightly: iSim 475 nonvacuous passes /
  4 disables vs dsim 474 / 5 (same 2282 evaluations) — likely a
  reset-boundary counting difference, unadjudicated.

---

## 2. FPU testbench (`isim-custom-fp-run`) — GREEN, cycle-exact with dsim

**Status: FIXED — SW-515400 (iSim, 2026-08-26). `EXIT SUCCESS` at time
89040, identical to dsim 2026. github#958 CLOSED: the filed
mdrv/concatz/part_pv lowering refusals were COLLATERAL of one
elaboration bug — an element select of a packed-array-of-ENUM parameter
(`FmtUnitTypes[fmt]`) was read as a flat BIT select of the flattened
value, so `== DISABLED` held for every format and
fpnew_opgroup_block's generate chain tied off ALL formats including the
active one, double-driving the merged format's handshake nets. Graded
upstream by `integ_cv32e40p_fpu_run` (+ the elab-only twin) and the
`isim_sv_27_05_enum_array_param_elem_generate_cond` sv_lrm entry.**

**Elaboration ladder, all landed on iSim `main`** (each dsim-verified,
each with an `sv_lrm`/`integration` regression): SW-514900 (stored `.v`
bodies reparsed as SV2012 at library load — the pa_fdsu `:/ ` mislex
recurrence), SW-515000 (struct-param member element select,
`Implementation.PipeRegs[opgrp]`), SW-515100 (const function reading its
own local struct member, `super_format`), SW-515200 (runtime-prefix
partial packed selects + `'{default:}` in ternary arms), SW-515300
(enum-element select typing + pattern-to-element binding).  With these,
`make isim-elab-tb-fp` analyses, elaborates, compiles and links the full
FPU image (vendored fpnew, `-defparam tb_top.FPU=1`), and
`make isim-custom-fp-run` RUNS it.

**Remaining wall (runtime)**: the run reaches the 2M-cycle limit with no
program output.  `rejected-loud=33` in SIR lowering, all one cluster —
`fpnew_opgroup_block.sv:76-77/202`: module output ports driving DISJOINT
STRUCT MEMBERS of one packed-array element
(`.result_o(fmt_outputs[FMT].result)`, `.status_o(...)`, ...), which
elaborates to a >64-bit multi-driven net with part-write drivers.  Three
named refusals: `net.mdrv` (no resolver synthesized), `lpm.concatz`
(>64-bit multi-driven output), `lpm.part_pv` (non-part-write driver mate).
The driven net never updates, so the FP handshake never completes.  This
is real structural-lowering work in iSim (tgt_sir.cc:4135/7358/13118),
not a testbench issue.

**Testbench-side fixes committed here** (all toolchain/stale-glue class,
program text untouched; dsim runs the result to `EXIT SUCCESS` at time
89040): `crt0.S` enables `mstatus.FS` under `__riscv_flen` (the current
RTL implements FS, the 2019 crt0 predates it — without it every F
instruction traps); `custom_fp` builds with `-mabi=ilp32` (single-
multilib toolchain; ISA stays rv32imfc, F instructions verified present
by objdump) and `-Wno-error=int-conversion` (GCC>=14).

---

## Closed items (fixed in iSim, removed from active tracking)

- **DPI-C export unsupported formal types** (was item 1, github#639):
  `read_byte`'s 4-state `logic` input formal fixed as SW-514500;
  `write_byte`'s output-arg task formals fixed as SW-514600. Both landed
  on `main` 2026-08-25; `make isim-elab-tb` now elaborates, compiles and
  links the full testbench image end-to-end (~4 min).
- **`isim-elab-tb` 20+-minute/10GB clang hang**: the 4.2M-line generated
  sensitivity function (one wakeup registration per array WORD nexus for
  `mm_ram.sv:187`'s address decode, collapsing to 13 real kernel signal
  ids) fixed as SW-514700 (dedup by resolved `(signal_id, edge)`); with
  SW-514400 (`NexusSet::bsearch_` O(n)→O(1)) landed just before it. The
  `.ll` dropped 329MB→22.7MB. This also answers the "one entry per array
  element vs whole-aggregate" architectural question recorded earlier:
  the per-element NexusSet stays (order-preserving, correct), and the
  redundancy is removed where it is provably safe — at kernel signal-id
  resolution.
- Automatic-lifetime `SvWarning` noise (SW-510000/511000/514300), the
  packed-struct/`>64-bit` automatic-noinit gap (SW-513000) — earlier
  session, landed on `main`.
