
module bp_pma
 import bp_common_pkg::*;
 import bp_common_aviary_pkg::*;
 import bp_common_cfg_link_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_inv_cfg
   `declare_bp_proc_params(bp_params_p)

   , localparam cfg_bus_width_lp = `bp_cfg_bus_width(vaddr_width_p, core_id_width_p, cce_id_width_p, lce_id_width_p, cce_pc_width_p, cce_instr_width_p)
   )
  (input                          clk_i
   , input                        reset_i
   , input [cfg_bus_width_lp-1:0] cfg_bus_i
  
   , input                        ptag_v_i
   , input [ptag_width_p-1:0]     ptag_i

   , output                       uncached_o
   , output [7:0]                 domain_data_o
   , output                       sac_data_o
   );

  `declare_bp_cfg_bus_s(vaddr_width_p, core_id_width_p, cce_id_width_p, lce_id_width_p, cce_instr_width_p);
  
  bp_cfg_bus_s cfg_bus_cast_i;
  assign cfg_bus_cast_i = cfg_bus_i;
   
  wire is_local_addr = (ptag_i < (dram_base_addr_gp >> page_offset_width_p));
  wire is_io_addr    = (ptag_i[ptag_width_p-1-:io_noc_did_width_p] != '0);

  // Address map (40 bits)
  // | did | sac_not_cc | tile ID | remaining |
  // |  3  |      1     |  log(N) |

  // Enabled DIDs
  logic [7:0] domain_data_r;
  bsg_dff_reset_en
    #(.width_p(8)
     ,.reset_val_p(1)
     )
     domain_reg
     (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.en_i(cfg_bus_cast_i.domain_w_v)
     ,.data_i(cfg_bus_cast_i.domain)
     ,.data_o(domain_data_r)
     );

  logic sac_data_r;
  bsg_dff_reset_en
    #(.width_p(1)
     ,.reset_val_p(0)
     )
     sac_reg
     (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.en_i(cfg_bus_cast_i.sac_w_v)
     ,.data_i(cfg_bus_cast_i.sac)
     ,.data_o(sac_data_r)
     );

  // We want the 0th domain to be enabled always
  assign domain_data_o = domain_data_r | 8'h1;
  assign sac_data_o = sac_data_r;

  assign uncached_o = ptag_v_i & (is_local_addr | is_io_addr);

endmodule

