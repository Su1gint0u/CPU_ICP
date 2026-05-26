# Extra grade 5 coverage for raw single-precision integer/FP moves.
.globl main

main:
    lui     x5, 0x3f800
    fmv.w.x f0, x5
    fmv.x.w x6, f0

    lui     x7, 0xbf000
    fmv.w.x f1, x7
    fadd.s  f2, f0, f1
    fmv.x.w x8, f2

    lui     x9, 0x80000
    fmv.w.x f3, x9
    fmv.x.w x10, f3

    lui     x11, 0x7fc12
    addi    x11, x11, 0x345
    fmv.w.x f4, x11
    fmv.x.w x12, f4
