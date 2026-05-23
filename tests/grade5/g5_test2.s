_start:
    ####################################################################
    # Fixed memory layout, base = 0x00000000
    #
    # x_array       at 0x00000000
    # u_array       at 0x00000014
    # divisor       at 0x00000028
    # temp_float    at 0x0000002C
    # out_signed    at 0x00000030
    # out_unsigned  at 0x00000044
    ####################################################################

    addi x8,  x0, 0              # x8  = 0x00000000 = x_array base
    addi x9,  x0, 20             # x9  = 0x00000014 = u_array base
    addi x18, x0, 40             # x18 = 0x00000028 = divisor address
    addi x19, x0, 44             # x19 = 0x0000002C = temp_float address
    addi x20, x0, 48             # x20 = 0x00000030 = out_signed base
    addi x21, x0, 68             # x21 = 0x00000044 = out_unsigned base


    ####################################################################
    # Setup loop
    #
    # Initializes:
    #   x_array = { 100, -50, 25, -200, 7 }
    #   u_array = { 20, 10, 100, 3, 5 }
    ####################################################################

    addi x5, x0, 0               # i = 0
    addi x6, x0, 5               # N = 5

setup_loop:
    bge  x5, x6, setup_divisor

    beq  x5, x0, setup_i0

    addi x7, x0, 1
    beq  x5, x7, setup_i1

    addi x7, x0, 2
    beq  x5, x7, setup_i2

    addi x7, x0, 3
    beq  x5, x7, setup_i3

setup_i4:
    addi x28, x0, 7              # x[4] = 7
    addi x29, x0, 5              # u[4] = 5
    jal  x0, setup_store

setup_i0:
    addi x28, x0, 100            # x[0] = 100
    addi x29, x0, 20             # u[0] = 20
    jal  x0, setup_store

setup_i1:
    addi x28, x0, -50            # x[1] = -50
    addi x29, x0, 10             # u[1] = 10
    jal  x0, setup_store

setup_i2:
    addi x28, x0, 25             # x[2] = 25
    addi x29, x0, 100            # u[2] = 100
    jal  x0, setup_store

setup_i3:
    addi x28, x0, -200           # x[3] = -200
    addi x29, x0, 3              # u[3] = 3

setup_store:
    slli x30, x5, 2              # offset = i * 4

    add  x31, x8, x30
    sw   x28, 0(x31)             # x_array[i] = x28

    add  x31, x9, x30
    sw   x29, 0(x31)             # u_array[i] = x29

    addi x5, x5, 1
    jal  x0, setup_loop


setup_divisor:
    ####################################################################
    # divisor = 2.0f
    #
    # IEEE-754 single precision:
    #   2.0f = 0x40000000
    ####################################################################

    lui  x5, 0x40000             # x5 = 0x40000000
    sw   x5, 0(x18)              # store divisor


    ####################################################################
    # Main conversion loop
    #
    # C equivalent:
    #
    # for (int i = 0; i < 5; i++) {
    #     float xf = (float)x_array[i];
    #     float uf = (float)u_array[i];
    #     float y  = (xf - uf) / divisor;
    #
    #     out_signed[i]   = (int)y;
    #     out_unsigned[i] = (unsigned int)y;
    # }
    ####################################################################

    flw  f6, 0(x18)              # f6 = divisor

    addi x5, x0, 0               # i = 0
    addi x6, x0, 5               # N = 5

convert_loop:
    bge  x5, x6, convert_done

    slli x7, x5, 2               # offset = i * 4

    add  x28, x8, x7
    lw   x29, 0(x28)             # x29 = x_array[i]

    add  x28, x9, x7
    lw   x30, 0(x28)             # x30 = u_array[i]

    fcvt.s.w  f0, x29            # f0 = (float)x_array[i]
    fcvt.s.wu f1, x30            # f1 = (float)u_array[i]

    fsub.s f2, f0, f1            # f2 = xf - uf
    fdiv.s f3, f2, f6            # f3 = y

    fsw  f3, 0(x19)              # temp_float = y
    flw  f4, 0(x19)              # f4 = temp_float

    fcvt.w.s  x31, f4            # signed integer conversion
    fcvt.wu.s x10, f4            # unsigned integer conversion

    add  x28, x20, x7
    sw   x31, 0(x28)             # out_signed[i] = x31

    add  x28, x21, x7
    sw   x10, 0(x28)             # out_unsigned[i] = x10

    addi x5, x5, 1
    jal  x0, convert_loop


convert_done:
halt:
    jal x0, halt
