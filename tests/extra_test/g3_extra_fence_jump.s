# Extra grade 3 coverage for FENCE/FENCE.I plus explicit JAL/JALR link behavior.
.globl main

main:
    addi x5, x0, 0

    addi x6, x0, 0x12
    sb   x6, 0(x27)
    fence
    lbu  x7, 0(x27)

    addi x6, x0, 0x345
    sh   x6, 2(x27)
    fence.i
    lhu  x8, 2(x27)

    jal  x1, jal_ok
    addi x5, x5, 1
jal_ok:
    ori  x5, x5, 1

    auipc x12, 0
    addi  x12, x12, 16
    jalr  x13, 0(x12)
    addi  x5, x5, 2
jalr_ok:
    ori  x5, x5, 4
