
setup:
    # Setup coordinates by storing binary format of floating point values used later
    # -50 in IEEE 754
    lui x5, 0xc2480
    sw x5, x0, 0
    # 25 in IEEE 754
    lui x5, 0x41c80
    sw x5, x0, 4
    # 13 in IEEE 754
    lui x5, 0x41500
    sw x5, x0, 8
    # -5 in IEEE 754
    lui x5, 0xc0a00
    sw x5, x0, 12 

distance:
    # Coordinate structure
    # Name    Offset     Size (bytes)
    # x       0          4
    # y       4          4
    flw   f0, x0, 0      # f0 = from.x
    flw   f1, x0, 4      # f1 = from.y
    flw   f2, x0, 8      # f2 = to.x
    flw   f3, x0, 12      # f3 = to.y
    fsub.s  f0, f2, f0 # f0 = to.x - from.x
    fsub.s  f1, f3, f1 # f1 = to.y - from.y
    fmul.s  f0, f0, f0 # f0 = f0 * f0
    fmul.s  f1, f1, f1 # f1 = f1 * f1
    fadd.s  f0, f0, f1 # f0 = f0 + f1
    fsqrt.s f0, f0      # f0 = sqrt(f0)
    # Return value goes in f0
    ret
