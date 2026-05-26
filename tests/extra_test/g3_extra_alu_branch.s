# Extra grade 3 coverage for RV32I operations not exercised by the school tests.
.globl main

main:
    lui  x5, 0x00ff0
    addi x5, x5, 0x0f0

    slli x6, x5, 4
    srli x7, x6, 8

    lui  x28, 0xf0000
    srai x28, x28, 4

    addi x29, x0, 3
    sll  x8, x29, x29
    srl  x9, x6, x29
    sra  x10, x28, x29

    xor  x11, x6, x7
    xori x11, x11, -1
    or   x12, x8, x9
    ori  x12, x12, 0x055
    and  x13, x11, x12
    andi x13, x13, 0x07f

    slt   x14, x28, x6
    slti  x15, x28, -1
    sltu  x16, x28, x6
    sltiu x17, x6, -1

    slli x20, x14, 3
    slli x21, x15, 2
    or   x20, x20, x21
    slli x21, x16, 1
    or   x20, x20, x21
    or   x20, x20, x17

    addi x18, x0, 0

    beq  x14, x15, beq_taken_ok
    jal  x0, beq_taken_done
beq_taken_ok:
    ori  x18, x18, 0x001
beq_taken_done:
    beq  x14, x16, beq_not_taken_done
    ori  x18, x18, 0x002
beq_not_taken_done:

    bne  x16, x17, bne_taken_ok
    jal  x0, bne_taken_done
bne_taken_ok:
    ori  x18, x18, 0x004
bne_taken_done:
    bne  x14, x15, bne_not_taken_done
    ori  x18, x18, 0x008
bne_not_taken_done:

    blt  x28, x6, blt_taken_ok
    jal  x0, blt_taken_done
blt_taken_ok:
    ori  x18, x18, 0x010
blt_taken_done:
    blt  x6, x28, blt_not_taken_done
    ori  x18, x18, 0x020
blt_not_taken_done:

    bge  x6, x28, bge_taken_ok
    jal  x0, bge_taken_done
bge_taken_ok:
    ori  x18, x18, 0x040
bge_taken_done:
    bge  x28, x6, bge_not_taken_done
    ori  x18, x18, 0x080
bge_not_taken_done:

    bltu x6, x28, bltu_taken_ok
    jal  x0, bltu_taken_done
bltu_taken_ok:
    ori  x18, x18, 0x100
bltu_taken_done:
    bltu x28, x6, bltu_not_taken_done
    ori  x18, x18, 0x200
bltu_not_taken_done:

    bgeu x28, x6, bgeu_taken_ok
    jal  x0, bgeu_taken_done
bgeu_taken_ok:
    ori  x18, x18, 0x400
bgeu_taken_done:

    auipc x19, 0
