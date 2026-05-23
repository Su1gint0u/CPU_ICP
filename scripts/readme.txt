# 生成符合格式的bin文件
python3 build_bins.py

# 只看将执行什么，不真的跑 Vivado
python3 vivado_impl.py --dry-run

# 只生成 bit，不烧录
python3 vivado_impl.py --build-only

# 即使 RTL/XDC 没变，也重新烧录已有 bit
python3 vivado_impl.py --program-existing

# 只连接 FPGA 并烧录已有 bit，同时自动绑定同目录下的 .ltx
python3 vivado_impl.py --program-only

# 强制重新综合实现并烧录
python3 vivado_impl.py --force

运行测试
python3 run_fpga_compare.py ../tests/grade3/g3_test5.s

# 仅发送测试 bin 到 FPGA 并打印 UART 返回
python3 send_frame.py ../tests/grade3/g3_test1.s

# 导出 ILA 波形数据
# 在 Vivado Tcl Console 中:
#   source scripts/ila_export.tcl
#   ila_export
# 或命令行:
#   vivado -mode batch -source ila_export.tcl
