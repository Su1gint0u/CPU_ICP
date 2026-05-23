.section .text
    .global _start
    .balign 4
_start:
    lui sp, 0x80010

    # --- 阶段 1：测试系统存活 ---
    li a0, 65            # 打印 'A'
    lui t3, 0x10000
    sb a0, 0(t3)
    li t4, 20000
1:  addi t4, t4, -1; bnez t4, 1b

    # --- 阶段 2：测试 lla (auipc) 寻址 ---
    lla t5, str1         # 尝试计算字符串地址
    li a0, 66            # 没死机就打印 'B'
    sb a0, 0(t3)
    li t4, 20000
2:  addi t4, t4, -1; bnez t4, 2b

    # --- 阶段 3：测试 lbu (内存读取与 LSU) ---
lbu a6, 0(t5)        # 发起读取
    sb a6, 0(t3)         # 正常发送 '1'
    li t4, 20000
3:  addi t4, t4, -1; bnez t4, 3b

    # --- 阶段 4：测试 jal / ret (函数跳转) ---
    jal ra, test_func    # 尝试跳转
    
    ebreak
    j .

test_func:
    li a0, 67            # 打印 'C'
    sb a0, 0(t3)
    li t4, 20000
4:  addi t4, t4, -1; bnez t4, 4b
    ret                  # 尝试返回

    .balign 4
str1: .asciz "1+2 = "

.balign 4
    .word 0x00000000
.word 0x00000000
