// Shared CPU pipeline types (control bus + opcode class) for 5-stage core.
package cpu_pkg;

    typedef enum logic [2:0] {
        D_CMD_NONE = 3'b000,
        D_CMD_LD   = 3'b001,
        D_CMD_ST   = 3'b010,
        D_CMD_AMO  = 3'b011
    } d_cmd_e;

    typedef enum logic [2:0] {
        SZ_1B = 3'd0,
        SZ_2B = 3'd1,
        SZ_4B = 3'd2,
        SZ_8B = 3'd3
    } d_size_e;

    typedef enum logic [2:0] {
        CTL_FENCE      = 3'b000,
        CTL_FENCE_I    = 3'b001,
        CTL_FLUSH_LINE = 3'b010,
        CTL_FLUSH_ALL  = 3'b011
    } ctl_op_e;

    // ID/EX stage payload (decoded instruction + operands snapshot)
    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] inst;
        logic         fetch_err;
        logic [4:0]  rs1;
        logic [4:0]  rs2;
        logic [4:0]  rd;
        logic [6:0]  opcode;
        logic [2:0]  funct3;
        logic [6:0]  funct7;
        logic [31:0] imm_i;
        logic [31:0] imm_s;
        logic [31:0] imm_b;
        logic [31:0] imm_u;
        logic [31:0] imm_j;
        logic [31:0] rs1_val;
        logic [31:0] rs2_val;
        logic        regwrite;
        logic        mem_read;
        logic        mem_write;
        logic        is_load;
        logic        is_store;
        logic        is_branch;
        logic        is_jal;
        logic        is_jalr;
        logic        is_fence;
        logic [2:0]  fence_op;
        logic        is_csr;
        logic        is_muldiv;
    } id_ex_bus_t;

    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [4:0]  rd;
        logic        regwrite;
        logic        is_load;
        logic        is_store;
        logic [31:0] alu_result;
        logic [31:0] mem_addr;
        logic [2:0]  mem_cmd;
        logic [2:0]  mem_size;
        logic [31:0] store_wdata;
        logic [3:0]  store_wstrb;
        logic [2:0]  load_funct3;
    } ex_mem_bus_t;

    typedef struct packed {
        logic        valid;
        logic [4:0]  rd;
        logic        regwrite;
        logic [31:0] wb_data;
        logic [2:0]  load_funct3;
        logic        is_load;
    } mem_wb_bus_t;

endpackage : cpu_pkg
