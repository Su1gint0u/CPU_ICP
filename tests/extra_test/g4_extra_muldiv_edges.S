# Extra grade 4 coverage for RV32M division edge cases.
.globl main

main:
    lui  x5, 0x80000
    addi x6, x0, -1
    div  x7, x5, x6
    rem  x8, x5, x6

    addi x9, x0, 123
    addi x10, x0, 0
    div  x11, x9, x10
    divu x12, x9, x10
    rem  x13, x9, x10
    remu x14, x9, x10

    addi x15, x0, -100
    addi x16, x0, 7
    div  x17, x15, x16
    rem  x18, x15, x16
    mul  x19, x15, x16
