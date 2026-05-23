.globl main

main:
    lui x5, 0b11111111111111110111
    addi x5, x5, 0b010010100110
    lui x6, 0b00000000000000000111
    addi x6, x6, 0b001010100001

    mul x7, x5, x6
    mulh x8, x5, x6
    mulhsu x9, x6, x5
    mulhu x10, x5, x6

    div x11, x5, x6
    divu x12, x5, x6
    rem x13, x5, x6
    remu x14, x5, x6

