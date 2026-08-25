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

## 1. `Overriding the default variable lifetime is only partially supported outside a fork-statement capture` — recurring SvWarning across FP and testbench sources

**Status: OPEN**

**Where observed**: `make isim-analyze-fp` and `make isim-analyze-tb`
(NOT `make isim-analyze`, the core-RTL-only target — this warning never
fires there). Fires repeatedly across unrelated files:

- `rtl/vendor/pulp_platform_fpnew/src/fpnew_cast_multi.sv:683`
- `rtl/vendor/pulp_platform_fpnew/src/fpnew_opgroup_fmt_slice.sv:293`
- `rtl/vendor/pulp_platform_fpnew/src/fpnew_opgroup_multifmt_slice.sv:513`
- `example_tb/core/cv32e40p_random_interrupt_generator.sv:131,132`
- `example_tb/core/mm_ram.sv:249,250,251,252,253`
- `example_tb/core/tb_top.sv:70,71,114`

Exact message (identical every occurrence, only file:line changes):

```
=W:[SvWarning] <file>:<line>: warning: Overriding the default variable
lifetime is only partially supported outside a fork-statement capture of
this declaration; other uses still share one storage cell across
re-entries of this block.
```

**Why this is worth investigating first, not dismissing as noise**:
"partially supported" outside the one context (fork-statement capture)
where iSim's own lifetime-override handling is apparently complete is
exactly the shape of a correctness gap, not a style nit — if a variable
declared with an overridden (e.g. `automatic` inside a `static` task, or
vice versa) lifetime is read/written from more than one re-entry of its
enclosing block OUTSIDE a fork capture, and iSim silently shares one
storage cell across those re-entries where the LRM requires each entry
to get its own, that is silent-wrong: a value from a stale prior
invocation leaking into a new one, with no diagnostic escalation beyond
a warning. Needs determining:

1. Does ANY of the six flagged sites actually re-enter its enclosing
   block in a way that would expose this (recursion, a task called from
   more than one concurrent context, a loop-spawned block) — or is the
   warning firing on a declaration shape that happens to be syntactically
   eligible but never actually re-entered in practice, making it a true
   non-issue for this design specifically even if the underlying iSim
   gap is real?
2. If a real re-entry case exists here: does iSim actually compute the
   wrong value (MEASURE it, oracle-first against dsim 2026 per iSim's
   own CLAUDE.md discipline), or is the warning itself overly broad
   (correctly conservative, flagging a shape that iSim actually handles
   correctly today, just without high enough confidence to stay silent)?
3. Either way, file the finding against iSim with a minimal, oracle-first
   reduction — not against this fork's own RTL, which is upstream code
   we do not modify to work around iSim gaps.

**Next step**: reduce to a minimal repro isolating one of the six sites'
actual declaration/re-entry shape, run it through dsim 2026 first, then
iSim, and determine which of the three questions above is the answer
before deciding OPEN → FILED or OPEN → NOT-A-BUG.
