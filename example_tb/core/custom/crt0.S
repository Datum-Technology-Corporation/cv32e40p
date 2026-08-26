/* Copyright (c) 2017  SiFive Inc. All rights reserved.
 * Copyright (c) 2019  ETH Zürich and University of Bologna
 * This copyrighted material is made available to anyone wishing to use,
 * modify, copy, or redistribute it subject to the terms and conditions
 * of the FreeBSD License.   This program is distributed in the hope that
 * it will be useful, but WITHOUT ANY WARRANTY expressed or implied,
 * including the implied warranties of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE.  A copy of this license is available at
 * http://www.opensource.org/licenses.
 */

/* Entry point for bare metal programs */
.section .text.start
.global _start
.type _start, @function

_start:
/* initialize global pointer */
.option push
.option norelax
1:	auipc gp, %pcrel_hi(__global_pointer$)
	addi  gp, gp, %pcrel_lo(1b)
.option pop

/* initialize stack pointer */
	la sp, _sp

#if defined(__riscv_flen)
/* Enable the FPU state before any F instruction executes: the current
 * CV32E40P RTL implements mstatus.FS (reset value Off), under which every
 * floating-point instruction traps as illegal -- this crt0 predates that
 * RTL change (same stale-example_tb class as the COREV_PULP parameter
 * rename).  FS=01 (Initial) is the standard enable; the hardware upgrades
 * it to Dirty on the first FP write.  Guarded by __riscv_flen so only a
 * program actually compiled with the F extension executes the write --
 * non-FP builds (hello_world, interrupt) assemble exactly as before. */
	li t0, (1 << 13)
	csrs mstatus, t0
	csrr t1, mstatus	/* serialize: FS visible before 1st F insn */
#endif

/* set vector table address and vectored mode */
	la a0, __vector_start
        ori a0, a0, 0x1
	csrw mtvec, a0

/* clear the bss segment */
	la a0, __bss_start
	la a2, __bss_end
	sub a2, a2, a0
	li a1, 0
	call memset

/* new-style constructors and destructors */
	la a0, __libc_fini_array
	call atexit
	call __libc_init_array

/* call main */
	lw a0, 0(sp)                    /* a0 = argc */
	addi a1, sp, __SIZEOF_POINTER__ /* a1 = argv */
	li a2, 0                        /* a2 = envp = NULL */
	call main
	tail exit

.size  _start, .-_start

.global _init
.type   _init, @function
.global _fini
.type   _fini, @function
_init:
_fini:
 /* These don't have to do anything since we use init_array/fini_array. Prevent
    missing symbol error */
	ret
.size  _init, .-_init
.size _fini, .-_fini
