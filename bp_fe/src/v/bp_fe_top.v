/*
 * Name:
 *   bp_fe_top.v
 *
 * Description:
 *
 * Notes:
 *
 */

module bp_fe_top
 import bp_fe_pkg::*;
 import bp_fe_icache_pkg::*;
 import bp_common_pkg::*;
 import bp_common_aviary_pkg::*;
 import bp_common_rv64_pkg::*;
 import bp_be_pkg::*;
 import bp_common_cfg_link_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
   `declare_bp_proc_params(bp_params_p)
   `declare_bp_fe_be_if_widths(vaddr_width_p, paddr_width_p, asid_width_p, branch_metadata_fwd_width_p)
   `declare_bp_cache_service_if_widths(paddr_width_p, ptag_width_p, icache_sets_p, icache_assoc_p, dword_width_p, icache_block_width_p, icache_fill_width_p, icache)

   , localparam cfg_bus_width_lp = `bp_cfg_bus_width(vaddr_width_p, core_id_width_p, cce_id_width_p, lce_id_width_p, cce_pc_width_p, cce_instr_width_p)
   )
  (input                                              clk_i
   , input                                            reset_i

   , input [cfg_bus_width_lp-1:0]                     cfg_bus_i

   // Front End - Back End Interface
   , input [fe_cmd_width_lp-1:0]                      fe_cmd_i
   , input                                            fe_cmd_v_i
   , output logic                                     fe_cmd_yumi_o

   , output logic [fe_queue_width_lp-1:0]             fe_queue_o
   , output logic                                     fe_queue_v_o
   , input                                            fe_queue_ready_i

    // Cache Engine Interface
   , output logic [icache_req_width_lp-1:0]           cache_req_o
   , output logic                                     cache_req_v_o
   , input                                            cache_req_ready_i
   , output logic [icache_req_metadata_width_lp-1:0]  cache_req_metadata_o
   , output logic                                     cache_req_metadata_v_o
   , input                                            cache_req_complete_i
   , input                                            cache_req_critical_i

   , input [icache_data_mem_pkt_width_lp-1:0]         data_mem_pkt_i
   , input                                            data_mem_pkt_v_i
   , output logic                                     data_mem_pkt_yumi_o
   , output logic [icache_block_width_p-1:0]          data_mem_o

   , input [icache_tag_mem_pkt_width_lp-1:0]          tag_mem_pkt_i
   , input                                            tag_mem_pkt_v_i
   , output logic                                     tag_mem_pkt_yumi_o
   , output logic [icache_tag_info_width_lp-1:0]      tag_mem_o

   , input [icache_stat_mem_pkt_width_lp-1:0]         stat_mem_pkt_i
   , input                                            stat_mem_pkt_v_i
   , output logic                                     stat_mem_pkt_yumi_o
   , output logic [icache_stat_info_width_lp-1:0]     stat_mem_o
   );

  `declare_bp_fe_be_if(vaddr_width_p, paddr_width_p, asid_width_p, branch_metadata_fwd_width_p);
  `declare_bp_cfg_bus_s(vaddr_width_p, core_id_width_p, cce_id_width_p, lce_id_width_p, cce_pc_width_p, cce_instr_width_p);
  `declare_bp_fe_branch_metadata_fwd_s(btb_tag_width_p, btb_idx_width_p, bht_idx_width_p, ghist_width_p); 
  `bp_cast_i(bp_cfg_bus_s, cfg_bus);

  // State machine declaration
  enum logic [1:0] {e_wait=2'd0, e_resume, e_run} state_n, state_r;
  
  wire is_wait   = (state_r == e_wait);
  wire is_resume = (state_r == e_resume);
  wire is_run    = (state_r == e_run);
  
  /////////////////
  // FE cmd decoding
  `bp_cast_i(bp_fe_cmd_s, fe_cmd); 
  logic fe_instr_v, fe_exception_v;
  logic next_pc_yumi_li, attaboy_yumi_lo;

  wire state_reset_v    = fe_cmd_v_i & (fe_cmd_cast_i.opcode == e_op_state_reset); 
  wire pc_redirect_v    = fe_cmd_v_i & (fe_cmd_cast_i.opcode == e_op_pc_redirection);
  wire itlb_fill_v      = fe_cmd_v_i & (fe_cmd_cast_i.opcode == e_op_itlb_fill_response);
  wire icache_fence_v   = fe_cmd_v_i & (fe_cmd_cast_i.opcode == e_op_icache_fence);
  wire icache_fill_v    = fe_cmd_v_i & (fe_cmd_cast_i.opcode == e_op_icache_fill_response);
  wire itlb_fence_v     = fe_cmd_v_i & (fe_cmd_cast_i.opcode == e_op_itlb_fence);
  wire attaboy_v        = fe_cmd_v_i & (fe_cmd_cast_i.opcode == e_op_attaboy);
  wire cmd_nonattaboy_v = fe_cmd_v_i & (fe_cmd_cast_i.opcode != e_op_attaboy);

  wire trap_v        = pc_redirect_v
                       & (fe_cmd_cast_i.operands.pc_redirect_operands.subopcode == e_subop_trap);
  wire ret_v         = pc_redirect_v
                       & (fe_cmd_cast_i.operands.pc_redirect_operands.subopcode == e_subop_eret);
  wire switch_v      = pc_redirect_v
                       & (fe_cmd_cast_i.operands.pc_redirect_operands.subopcode == e_subop_translation_switch);
  wire br_miss_v     = pc_redirect_v
                       & (fe_cmd_cast_i.operands.pc_redirect_operands.subopcode == e_subop_branch_mispredict);
  wire br_res_taken  = (attaboy_v & fe_cmd_cast_i.operands.attaboy.taken)
                       | (br_miss_v & (fe_cmd_cast_i.operands.pc_redirect_operands.misprediction_reason == e_incorrect_pred_taken));
  wire br_res_ntaken = (attaboy_v & ~fe_cmd_cast_i.operands.attaboy.taken)
                       | (br_miss_v & (fe_cmd_cast_i.operands.pc_redirect_operands.misprediction_reason == e_incorrect_pred_ntaken));
  wire br_miss_nonbr = br_miss_v & (fe_cmd_cast_i.operands.pc_redirect_operands.misprediction_reason == e_not_a_branch);

  assign fe_cmd_yumi_o = (cmd_nonattaboy_v & next_pc_yumi_li) | attaboy_yumi_lo;

  /////////////////////////////////////////////////////////////////////////////
  // PC Generation
  /////////////////////////////////////////////////////////////////////////////
  logic [vaddr_width_p-1:0] icache_vaddr_tl_lo, fetch_pc_lo;
  logic override_lo;
  logic tl_we_lo, tl_v_lo;
  bp_fe_branch_metadata_fwd_s fetch_br_metadata_lo;
  logic [instr_width_p-1:0] icache_data_lo;
  logic icache_data_v_lo, icache_data_yumi_li;
  logic tv_we_lo, tv_v_lo;

  bp_fe_branch_metadata_fwd_s redirect_br_metadata_li;
  wire [vaddr_width_p-1:0] redirect_pc_li = fe_cmd_yumi_o ? fe_cmd_cast_i.vaddr : fetch_pc_lo;
  assign redirect_br_metadata_li          = fe_cmd_cast_i.operands.pc_redirect_operands.branch_metadata_fwd;
  wire redirect_br_taken_li               = br_res_taken;
  wire redirect_v_li                      = cmd_nonattaboy_v;

  bp_fe_branch_metadata_fwd_s attaboy_br_metadata_li;
  assign attaboy_br_metadata_li = fe_cmd_cast_i.operands.attaboy.branch_metadata_fwd;
  wire attaboy_v_li = attaboy_v;

  logic [vaddr_width_p-1:0] next_pc_lo;
  bp_fe_pc_gen
   #(.bp_params_p(bp_params_p))
   pc_gen
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
  
     ,.redirect_pc_i(redirect_pc_li)
     ,.redirect_br_metadata_i(redirect_br_metadata_li)
     ,.redirect_br_taken_i(redirect_br_taken_li)
     ,.redirect_v_i(redirect_v_li)

     ,.next_pc_o(next_pc_lo)

     ,.override_o(override_lo)
     ,.tl_we_i(tl_we_lo)
     ,.tl_pc_i(icache_vaddr_tl_lo)
  
     ,.fetch_instr_i(icache_data_lo)
     ,.fetch_br_metadata_o(fetch_br_metadata_lo)
     ,.fetch_yumi_i(icache_data_yumi_li)
     ,.tv_we_i(tv_we_lo)
     ,.tv_pc_i(fetch_pc_lo)
  
     ,.attaboy_br_metadata_i(attaboy_br_metadata_li)
     ,.attaboy_v_i(attaboy_v_li)
     ,.attaboy_yumi_o(attaboy_yumi_lo)
     );

  /////////////////////////////////////////////////////////////////////////////
  // MMU
  /////////////////////////////////////////////////////////////////////////////
  logic [rv64_priv_width_gp-1:0] shadow_priv_n, shadow_priv_r;
  logic shadow_translation_en_n, shadow_translation_en_r;

  wire shadow_w = state_reset_v | trap_v | ret_v | switch_v;
  assign shadow_priv_n = fe_cmd_cast_i.operands.pc_redirect_operands.priv;
  assign shadow_translation_en_n = fe_cmd_cast_i.operands.pc_redirect_operands.translation_enabled;
  bsg_dff_reset_en_bypass
   #(.width_p(rv64_priv_width_gp+1))
   shadow_reg
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.en_i(shadow_w)
  
     ,.data_i({shadow_priv_n, shadow_translation_en_n})
     ,.data_o({shadow_priv_r, shadow_translation_en_r})
     );

  bp_pte_entry_leaf_s itlb_r_entry, entry_lo, passthrough_entry, fill_entry;
  logic itlb_r_v_lo, itlb_v_lo, itlb_miss_lo, passthrough_v_lo, fill_v_r;
  bp_tlb
   #(.bp_params_p(bp_params_p), .tlb_els_p(itlb_els_p))
   itlb
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.flush_i(itlb_fence_v)
  
     ,.v_i((next_pc_yumi_li | itlb_fill_v) & shadow_translation_en_r)
     ,.w_i(itlb_fill_v)
     ,.vtag_i(next_pc_lo[vaddr_width_p-1-:vtag_width_p])
     ,.entry_i(fe_cmd_cast_i.operands.itlb_fill_response.pte_entry_leaf)
  
     ,.v_o(itlb_v_lo)
     ,.miss_v_o(itlb_miss_lo)
     ,.entry_o(entry_lo)
     );
  
  // Forward the fill entry since we have a 1RW TLB
  bsg_dff_en
   #(.width_p($bits(bp_pte_entry_leaf_s)))
   fill_entry_reg
    (.clk_i(clk_i)
     ,.en_i(itlb_fill_v)
     ,.data_i(fe_cmd_cast_i.operands.itlb_fill_response.pte_entry_leaf)
     ,.data_o(fill_entry)
     );

  bsg_dff_reset_set_clear
   #(.width_p(1))
   fill_entry_v_reg
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.set_i(itlb_fill_v)
     ,.clear_i(next_pc_yumi_li)
     ,.data_o(fill_v_r)
     );
  assign passthrough_entry = '{ptag: icache_vaddr_tl_lo[vaddr_width_p-1-:vtag_width_p], default: '0};
  assign passthrough_v_lo  = tl_v_lo;
  assign itlb_r_entry      = shadow_translation_en_r ? fill_v_r ? fill_entry : entry_lo : passthrough_entry;
  assign itlb_r_v_lo       = shadow_translation_en_r ? (itlb_v_lo | fill_v_r) : passthrough_v_lo;

  logic uncached_li;
  bp_pma
   #(.bp_params_p(bp_params_p))
   pma
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.ptag_v_i(itlb_r_v_lo)
     ,.ptag_i(itlb_r_entry.ptag)
  
     ,.uncached_o(uncached_li)
     );

  /////////////////
  // Fault detection
  wire [ptag_width_p-1:0] ptag_li = itlb_r_entry.ptag;
  wire is_uncached_mode           = (cfg_bus_cast_i.icache_mode == e_lce_mode_uncached);
  wire mode_fault_v               = (is_uncached_mode & ~uncached_li);
  wire did_fault_v                = (ptag_li[ptag_width_p-1-:io_noc_did_width_p] != '0);
  wire instr_priv_page_fault      = ((shadow_priv_r == `PRIV_MODE_S) & itlb_r_entry.u)
                                      | ((shadow_priv_r == `PRIV_MODE_U) & ~itlb_r_entry.u);
  wire instr_exe_page_fault       = ~itlb_r_entry.x;
  wire instr_access_fault_v       = itlb_r_v_lo & (mode_fault_v | did_fault_v);
  wire instr_page_fault_v         = itlb_r_v_lo & shadow_translation_en_r & (instr_priv_page_fault | instr_exe_page_fault);

  wire ptag_v_li = itlb_r_v_lo & ~instr_access_fault_v & ~instr_page_fault_v;

  logic itlb_miss_r, instr_access_fault_r, instr_page_fault_r;
  bsg_dff_reset_en
   #(.width_p(3))
   fault_reg
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.en_i(tv_we_lo)
     ,.data_i({itlb_miss_lo, instr_access_fault_v, instr_page_fault_v})
     ,.data_o({itlb_miss_r, instr_access_fault_r, instr_page_fault_r})
     );

  /////////////////////////////////////////////////////////////////////////////
  // I$
  /////////////////////////////////////////////////////////////////////////////
  `declare_bp_fe_icache_pkt_s(vaddr_width_p);
  bp_fe_icache_pkt_s icache_pkt;
  assign icache_pkt =
    '{vaddr: next_pc_lo
      ,op  : icache_fence_v ? e_icache_fencei : icache_fill_v ? e_icache_fill : e_icache_fill
      };

  logic icache_miss_not_data_lo;
  bp_fe_icache 
   #(.bp_params_p(bp_params_p)) 
   icache
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
  
     ,.cfg_bus_i(cfg_bus_i)
 
     ,.icache_pkt_i(icache_pkt)
     ,.force_i(is_resume | pc_redirect_v)
     ,.v_i(state_n == e_run)
     ,.yumi_o(next_pc_yumi_li)

     ,.ptag_i(ptag_li)
     ,.ptag_v_i(ptag_v_li)
     ,.ptag_uncached_i(uncached_li)
     ,.poison_i(cmd_nonattaboy_v | override_lo | fe_exception_v)
     ,.tl_we_o(tl_we_lo)
     ,.tl_v_o(tl_v_lo)
     ,.tl_vaddr_o(icache_vaddr_tl_lo)
  
     ,.data_o(icache_data_lo)
     ,.miss_not_data_o(icache_miss_not_data_lo)
     ,.data_v_o(icache_data_v_lo)
     ,.data_yumi_i(icache_data_yumi_li)
     ,.tv_we_o(tv_we_lo)
     ,.tv_v_o(tv_v_lo)
     ,.tv_vaddr_o(fetch_pc_lo)
  
     ,.cache_req_o(cache_req_o)
     ,.cache_req_v_o(cache_req_v_o)
     ,.cache_req_ready_i(cache_req_ready_i & ~cmd_nonattaboy_v)
     ,.cache_req_metadata_o(cache_req_metadata_o)
     ,.cache_req_metadata_v_o(cache_req_metadata_v_o)
     ,.cache_req_complete_i(cache_req_complete_i)
     ,.cache_req_critical_i(cache_req_critical_i)
  
     ,.data_mem_pkt_i(data_mem_pkt_i)
     ,.data_mem_pkt_v_i(data_mem_pkt_v_i)
     ,.data_mem_pkt_yumi_o(data_mem_pkt_yumi_o)
     ,.data_mem_o(data_mem_o)
  
     ,.tag_mem_pkt_i(tag_mem_pkt_i)
     ,.tag_mem_pkt_v_i(tag_mem_pkt_v_i)
     ,.tag_mem_pkt_yumi_o(tag_mem_pkt_yumi_o)
     ,.tag_mem_o(tag_mem_o)
  
     ,.stat_mem_pkt_v_i(stat_mem_pkt_v_i)
     ,.stat_mem_pkt_i(stat_mem_pkt_i)
     ,.stat_mem_pkt_yumi_o(stat_mem_pkt_yumi_o)
     ,.stat_mem_o(stat_mem_o)
     );
  assign icache_data_yumi_li = icache_data_v_lo & fe_queue_ready_i;
  wire icache_miss           = icache_data_v_lo & icache_miss_not_data_lo;

  /////////////////////////////////////////////////////////////////////////////
  // FE queue interface
  /////////////////////////////////////////////////////////////////////////////
  `bp_cast_o(bp_fe_queue_s, fe_queue);
  assign fe_instr_v     = ~cmd_nonattaboy_v & fe_queue_ready_i & icache_data_v_lo;
  assign fe_exception_v = ~cmd_nonattaboy_v & fe_queue_ready_i & (instr_access_fault_r | instr_page_fault_r | itlb_miss_r | icache_miss);
  assign fe_queue_v_o   = fe_instr_v | fe_exception_v;
  always_comb
    begin
      fe_queue_cast_o = '0;
  
      if (fe_exception_v)
        begin
          fe_queue_cast_o.msg_type                     = e_fe_exception;
          fe_queue_cast_o.msg.exception.vaddr          = fetch_pc_lo;
          fe_queue_cast_o.msg.exception.exception_code = itlb_miss_r
                                                         ? e_itlb_miss
                                                         : icache_miss
                                                           ? e_icache_miss
                                                           : instr_page_fault_r
                                                             ? e_instr_page_fault
                                                             : e_instr_access_fault;
        end
      else 
        begin
          fe_queue_cast_o.msg_type                      = e_fe_fetch;
          fe_queue_cast_o.msg.fetch.pc                  = fetch_pc_lo;
          fe_queue_cast_o.msg.fetch.instr               = icache_data_lo;
          fe_queue_cast_o.msg.fetch.branch_metadata_fwd = fetch_br_metadata_lo;
        end
    end

  /////////////////////////////////////////////////////////////////////////////
  // Fetch state machine
  /////////////////////////////////////////////////////////////////////////////
  always_comb
    case (state_r)
      e_wait   : state_n = cmd_nonattaboy_v ? e_run : e_wait;
      e_run    : state_n = fe_exception_v ? e_wait : e_run;
      default: state_n = e_wait;
    endcase

  // synopsys sync_set_reset "reset_i"
  always_ff @(posedge clk_i)
    if (reset_i)
        state_r <= e_wait;
    else
      begin
        state_r <= state_n;
      end

endmodule

