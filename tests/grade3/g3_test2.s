    lui x8, 0x80000
    addi x8, x8, 0x000

    lui x9, 0xffff
    addi x9, x0, 15

loop:
    addi x9, x9, -1
    srai x8, x8, 1
    nop
    bne x9, x0, loop

    nop
    nop

