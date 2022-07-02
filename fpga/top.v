module top (
    // LEDs
    output p_led_sts_r,
    output p_led_sts_g,
    output p_led_in1_r,
    output p_led_in1_g,
    output p_led_in2_r,
    output p_led_in2_g,
    output p_led_in3_r,
    output p_led_in3_g,
    output p_led_in4_r,
    output p_led_in4_g,
    // ADC clocks: on pin 15 we have output, on pin 20 we have input
    output p_adc_sclk,
    input p_adc_sclk_gbin,
    // ADC data and sync
    input p_adc1_sda,
    input p_adc1_sdb,
    output p_adc1_cs_n,
    input p_adc2_sda,
    input p_adc2_sdb,
    output p_adc2_cs_n,
    // External I/O,
    inout [8:1] p_extio,
    // SPI DAC,
    output p_spi_dac_mosi,
    output p_spi_dac_sclk,
    output p_spi_dac_sync_n,
    // System clocks
    input p_clk_20mhz_gbin1,
    input p_clk_20mhz_gbin2,
    output p_clk_out,
    input p_clk_ref_in,
    output p_clk_out_sel,
    // FTDI GPIO
    input p_ft_io1,
    input p_ft_io2,
    // FTDI FIFO
    input p_ft_fifo_clkout,
    output p_ft_fifo_oe_n,
    output p_ft_fifo_siwu,
    output p_ft_fifo_wr_n,
    output p_ft_fifo_rd_n,
    input p_ft_fifo_txe_n,
    input p_ft_fifo_rxf_n,
    inout [7:0] p_ft_fifo_d
);

    `include "mreq_defines.vh"

    // ===============================================================================================================
    // =========================                                                             =========================
    // =========================                        CLOCK GENERATION                     =========================
    // =========================                                                             =========================
    // ===============================================================================================================

    // ------------------------------------------
    //                  ADC PLL
    //
    // input: 20MHz
    // output: 80MHz
    // ------------------------------------------
    wire adc_pll_out;
    wire adc_pll_lock;

    SB_PLL40_CORE #(
        .FEEDBACK_PATH("SIMPLE"),
		.DIVR(4'd0),
		.DIVF(7'd31),
		.DIVQ(3'd3),
		.FILTER_RANGE(3'd2),
        .PLLOUT_SELECT("GENCLK")
    ) adc_pll (
        .REFERENCECLK (p_clk_20mhz_gbin1),  // 20 MHz
        .PLLOUTCORE (adc_pll_out),
        .LOCK (adc_pll_lock),
        .RESETB(1'b1),
        .BYPASS(1'b0)
    );

    // Output PLL clock on the pin
    assign p_adc_sclk = adc_pll_out;


    // ===============================================================================================================
    // =========================                                                             =========================
    // =========================                      SYSTEM CLOCK DOMAIN                    =========================
    // =========================                       @(posedge sys_clk)                    =========================
    // =========================                                                             =========================
    // ===============================================================================================================

    // ADC controller is clocked from (negedge p_adc_sclk_gbin)
    wire sys_clk_neg = p_adc_sclk_gbin;
    // System clock domain is clocked from (posedge sys_clk)
    // Because we want it to be exactly the same clock as ADC's, we set sys_clk=~p_adc_sclk_gbin
    wire sys_clk = ~p_adc_sclk_gbin;

    // --------------------------------------------------
    // System reset generator
    // --------------------------------------------------

    // Reset asserted on:
    //  - FPGA reconfiguration (power on)
    //  - Asynchronously when sys_rst_req goes high
    // Reset deasserted on:
    //  - First sys_clk cycle when sys_rst_req is low
    reg sys_rst = 1'b1;
    wire sys_rst_req;

    always @(posedge sys_clk or posedge sys_rst_req) begin
        sys_rst <= 1'b0;
        if (sys_rst_req) begin
            sys_rst <= 1'b1;
        end
    end

    // --------------------------------------------------
    //      ADCT - ADC timing generators
    // --------------------------------------------------


    // Sample rate generators (SRATE pulses)
    //
    //                      +----> [adct_srate1_psc] ----> adct_srate1 ----> [ADC1]
    //  sys_clk (80MHz) ->--+
    //                      +----> [adct_srate2_psc] ----> adct_srate2 ----> [ADC2]
    //
    wire adct_srate1, adct_srate2;

    // CSR (control & status register) values
    wire csr_adct_srate1_en, csr_adct_srate2_en;
    wire [7:0] csr_adct_srate1_psc_div, csr_adct_srate2_psc_div;

    fastcounter #(
        .NBITS(8)
    ) adct_srate1_psc (
        .i_clk(sys_clk),
        .i_rst(sys_rst),
        .i_mode(1'b0),      // AUTORELOAD
        .i_en(csr_adct_srate1_en),
        .i_load(1'b0),
        .i_load_q(csr_adct_srate1_psc_div),
        .o_carry(adct_srate1)
    );

    fastcounter #(
        .NBITS(8)
    ) adct_srate2_psc (
        .i_clk(sys_clk),
        .i_rst(sys_rst),
        .i_mode(1'b0),      // AUTORELOAD
        .i_en(csr_adct_srate2_en),
        .i_load(1'b0),
        .i_load_q(csr_adct_srate2_psc_div),
        .o_carry(adct_srate2)
    );

    //  Timing pulse generators
    //
    //  adct_srate1 --> [adct_puls1_psc] --> adct_puls1 --> [adct_puls1_dly] --> adct_puls1_d --> [adct_puls1_fmr] --> adct_puls1_w
    //  adct_srate2 --> [adct_puls2_psc] --> adct_puls2 --> [adct_puls2_dly] --> adct_puls2_d --> [adct_puls2_fmr] --> adct_puls2_w
    //

    wire adct_puls1, adct_puls2;        // single-cycle pulses synced with adct_srate*
    wire adct_puls1_d, adct_puls2_d;    // single-cycle pulses delayed w.r.t adct_puls*
    wire adct_puls1_w, adct_puls2_w;    // width-controlled version of adct_puls*_d

    // CSR values
    wire csr_adct_puls1_en, csr_adct_puls2_en;
    wire [22:0] csr_adct_puls1_psc_div, csr_adct_puls2_psc_div;
    wire [8:0] csr_adct_puls1_dly, csr_adct_puls2_dly;
    wire [15:0] csr_adct_puls1_pwidth, csr_adct_puls2_pwidth;

    // Pulse frequency prescalers
    fastcounter #(
        .NBITS(23)
    ) adct_puls1_psc (
        .i_clk(sys_clk),
        .i_rst(sys_rst),
        .i_mode(1'b0),      // AUTORELOAD
        .i_en(adct_srate1 & csr_adct_puls1_en),
        .i_load(1'b0),
        .i_load_q(csr_adct_puls1_psc_div),
        .o_carry(adct_puls1)
    );

    fastcounter #(
        .NBITS(23)
    ) adct_puls2_psc (
        .i_clk(sys_clk),
        .i_rst(sys_rst),
        .i_mode(1'b0),      // AUTORELOAD
        .i_en(adct_srate2 & csr_adct_puls2_en),
        .i_load(1'b0),
        .i_load_q(csr_adct_puls2_psc_div),
        .o_carry(adct_puls2)
    );

    // Pulse micro-delay (delay is in adc_clk periods, max delay is up to 2x adc_srate periods)
    fastcounter #(
        .NBITS(9)
    ) adct_puls1_dly (
        .i_clk(sys_clk),
        .i_rst(sys_rst),
        .i_mode(1'b1),      // ONESHOT
        .i_en(1'b1),
        .i_load(adct_puls1),
        .i_load_q(csr_adct_puls1_dly),
        .o_zpulse(adct_puls1_d)
    );

    fastcounter #(
        .NBITS(9)
    ) adct_puls2_dly (
        .i_clk(sys_clk),
        .i_rst(sys_rst),
        .i_mode(1'b1),      // ONESHOT
        .i_en(1'b1),
        .i_load(adct_puls2),
        .i_load_q(csr_adct_puls2_dly),
        .o_zpulse(adct_puls2_d)
    );

    // Pulse width formers (width specified in adc_srate periods)
    fastcounter #(
        .NBITS(16)  // enough for 16ms pulse @ adc_srate=4MHz
    ) adct_puls1_fmr (
        .i_clk(sys_clk),
        .i_rst(sys_rst),
        .i_mode(1'b1),      // ONESHOT
        .i_en(adct_srate1),
        .i_load(adct_puls1_d),
        .i_load_q(csr_adct_puls1_pwidth),
        .o_nzero(adct_puls1_w)
    );

    fastcounter #(
        .NBITS(16)
    ) adct_puls2_fmr (
        .i_clk(sys_clk),
        .i_rst(sys_rst),
        .i_mode(1'b1),      // ONESHOT
        .i_en(adct_srate2),
        .i_load(adct_puls2_d),
        .i_load_q(csr_adct_puls2_pwidth),
        .o_nzero(adct_puls2_w)
    );

    // --------------------------------------------------
    //     ADC - Analog-to-digital converters
    // --------------------------------------------------

    wire csr_adc_adc1_en, csr_adc_adc2_en;

    wire adc1_start = adct_srate1 & csr_adc_adc1_en;
    wire adc2_start = adct_srate2 & csr_adc_adc2_en;
    wire adc1_rdy;
    wire adc2_rdy;
    wire [13:0] adc1_data_a;
    wire [13:0] adc1_data_b;
    wire [13:0] adc2_data_a;
    wire [13:0] adc2_data_b;

    ad7357if adc1 (
        // interface
        .i_if_sclk(sys_clk_neg),
        .o_if_cs_n(p_adc1_cs_n),
        .i_if_sdata_a(p_adc1_sda),
        .i_if_sdata_b(p_adc1_sdb),
        // Control
        .i_rst(sys_rst),
        .i_sync(adc1_start),
        // Data
        .o_ready(adc1_rdy),
        .o_sample_a(adc1_data_a),
        .o_sample_b(adc1_data_b)
    );

    ad7357if adc2 (
        // interface
        .i_if_sclk(sys_clk_neg),
        .o_if_cs_n(p_adc2_cs_n),
        .i_if_sdata_a(p_adc2_sda),
        .i_if_sdata_b(p_adc2_sdb),
        // Control
        .i_rst(sys_rst),
        .i_sync(adc2_start),
        // Data
        .o_ready(adc2_rdy),
        .o_sample_a(adc2_data_a),
        .o_sample_b(adc2_data_b)
    );

    // -------------------------
    // ADC timing pulse latches
    // -------------------------

    // Here we latch adct_puls1/2 on adc1/2_start pulse (start of conversion),
    // so that it can be read later on adc1/2_rdy pulse (end of conversion)
    reg adc1_puls, adc2_puls;
    always @(posedge sys_clk) begin
        if (sys_rst) begin
            adc1_puls <= 1'b0;
            adc2_puls <= 1'b0;
        end else begin
            if (adc1_start)
                adc1_puls <= adct_puls1;
            if (adc2_start)
                adc2_puls <= adct_puls2;
        end
    end

    // ------------------
    // ADC data streams
    // ------------------

    // Here we latch ADC data when ADC controller gives a RDY pulse and provide the usual
    // data+ready+valid stream interface for downstream consumers

    // Stream 1 serves ADC1 and is synchronized by ADC1 srate
    // Stream 2 serves ADC2 and is synchronized by ADC2 srate
    // Each stream produces 32-bit data words with following layout:
    // MSB
    //  31      - 0
    //  30      - adc1(2)_puls
    //  29:16   - adc1(2)_data_b
    //  15      - 0
    //  14      - adc1(2)_puls
    //  13:0    - adc1(2)_data_a
    // LSB
    //
    // Thus, bits 14 and 30 contain timing pulses which can be used to precisely synchronize hardware
    // adc_puls pulse generators to the data stream

    // ADC1
    reg [31:0] adc1_str_data;
    reg adc1_str_valid;
    wire adc1_str_ready;

    always @(posedge sys_clk) begin
        if (sys_rst) begin
            adc1_str_data <= 32'b0;
            adc1_str_valid <= 1'b0;
        end else begin
            if (adc1_rdy) begin
                adc1_str_valid <= 1'b1;
                adc1_str_data <= {1'b0, adc1_puls, adc1_data_b, 1'b0, adc1_puls, adc1_data_a};
            end else begin
                if (adc1_str_ready) begin
                    adc1_str_valid <= 1'b0;
                end
            end
        end
    end

    // ADC2
    reg [31:0] adc2_str_data;
    reg adc2_str_valid;
    wire adc2_str_ready;

    always @(posedge sys_clk) begin
        if (sys_rst) begin
            adc2_str_data <= 32'b0;
            adc2_str_valid <= 1'b0;
        end else begin
            if (adc2_rdy) begin
                adc2_str_valid <= 1'b1;
                adc2_str_data <= {1'b0, adc2_puls, adc2_data_b, 1'b0, adc2_puls, adc2_data_a};
            end else begin
                if (adc2_str_ready) begin
                    adc2_str_valid <= 1'b0;
                end
            end
        end
    end

    // ---------------------------
    //          ADC FIFOs
    // ---------------------------
    localparam ADC_FIFO_ASIZE = 9;

    // ADC1
    wire adc1_fifo_empty, adc1_fifo_full, adc1_fifo_hfull, adc1_fifo_ovfl, adc1_fifo_udfl;
    wire [31:0] adc1_fifo_data;
    wire adc1_fifo_rd;

    assign adc1_str_ready = !adc1_fifo_full;

    syncfifo #(
        .ADDR_WIDTH(ADC_FIFO_ASIZE),
        .DATA_WIDTH(32)
    ) adc1_fifo (
        .i_clk(sys_clk),
        .i_rst(sys_rst),
        // data
        .i_data(adc1_str_data),
        .o_data(adc1_fifo_data),
        // control
        .i_wr(adc1_str_valid),
        .i_rd(adc1_fifo_rd),
        // status
        .o_empty(adc1_fifo_empty),
        .o_full(adc1_fifo_full),
        .o_half_full(adc1_fifo_hfull),
        .o_overflow(adc1_fifo_ovfl),
        .o_underflow(adc1_fifo_udfl)
    );

    // OVFL/UDFL flags latch
    wire adc1_fifo_ovfl_lclr, adc1_fifo_udfl_lclr;
    reg adc1_fifo_ovfl_lval, adc1_fifo_udfl_lval;
    always @(posedge sys_clk) begin
        if (sys_rst) begin
            adc1_fifo_ovfl_lval <= 1'b0;
            adc1_fifo_udfl_lval <= 1'b0;
        end else begin
            adc1_fifo_ovfl_lval <= adc1_fifo_ovfl | (adc1_fifo_ovfl_lval & ~adc1_fifo_ovfl_lclr);
            adc1_fifo_udfl_lval <= adc1_fifo_udfl | (adc1_fifo_udfl_lval & ~adc1_fifo_udfl_lclr);
        end
    end

    // ADC2
    wire adc2_fifo_empty, adc2_fifo_full, adc2_fifo_hfull, adc2_fifo_ovfl, adc2_fifo_udfl;
    wire [31:0] adc2_fifo_data;
    wire adc2_fifo_rd;

    assign adc2_str_ready = !adc2_fifo_full;

    syncfifo #(
        .ADDR_WIDTH(ADC_FIFO_ASIZE),
        .DATA_WIDTH(32)
    ) adc2_fifo (
        .i_clk(sys_clk),
        .i_rst(sys_rst),
        // data
        .i_data(adc2_str_data),
        .o_data(adc2_fifo_data),
        // control
        .i_wr(adc2_str_valid),
        .i_rd(adc2_fifo_rd),
        // status
        .o_empty(adc2_fifo_empty),
        .o_full(adc2_fifo_full),
        .o_half_full(adc2_fifo_hfull),
        .o_overflow(adc2_fifo_ovfl),
        .o_underflow(adc2_fifo_udfl)
    );

    // OVFL/UDFL flags latch
    wire adc2_fifo_ovfl_lclr, adc2_fifo_udfl_lclr;
    reg adc2_fifo_ovfl_lval, adc2_fifo_udfl_lval;
    always @(posedge sys_clk) begin
        if (sys_rst) begin
            adc2_fifo_ovfl_lval <= 1'b0;
            adc2_fifo_udfl_lval <= 1'b0;
        end else begin
            adc2_fifo_ovfl_lval <= adc2_fifo_ovfl | (adc2_fifo_ovfl_lval & ~adc2_fifo_ovfl_lclr);
            adc2_fifo_udfl_lval <= adc2_fifo_udfl | (adc2_fifo_udfl_lval & ~adc2_fifo_udfl_lclr);
        end
    end

    // -----------------------------------------------
    // EMREQ valid/ready state machine for ADC fifos
    // -----------------------------------------------

    // ADC1
    reg adc1_emreq_valid;
    wire adc1_emreq_ready;

    always @(posedge sys_clk) begin
        if (sys_rst) begin
            adc1_emreq_valid <= 1'b0;
        end else begin
            if (adc1_fifo_hfull) begin
                adc1_emreq_valid <= 1'b1;
            end else begin
                if (adc1_emreq_ready) begin
                    adc1_emreq_valid <= 1'b0;
                end
            end
        end
    end

    // ADC2
    reg adc2_emreq_valid;
    wire adc2_emreq_ready;

    always @(posedge sys_clk) begin
        if (sys_rst) begin
            adc2_emreq_valid <= 1'b0;
        end else begin
            if (adc2_fifo_hfull) begin
                adc2_emreq_valid <= 1'b1;
            end else begin
                if (adc2_emreq_ready) begin
                    adc2_emreq_valid <= 1'b0;
                end
            end
        end
    end

    // ------------------------
    // DAC driver
    // ------------------------

    wire csr_ftun_vtune_write;
    wire [15:0] csr_ftun_vtune_val;

    dac8551 #(
        .CLK_DIV(20)
    ) dac8551_i (
        .i_clk(sys_clk),
        .i_rst(sys_rst),
        .i_wr(csr_ftun_vtune_write),
        .i_wr_data({8'b0, csr_ftun_vtune_val}),
        .o_dac_sclk(p_spi_dac_sclk),
        .o_dac_sync_n(p_spi_dac_sync_n),
        .o_dac_mosi(p_spi_dac_mosi)
    );

    // -------------------------------------------
    // FTDI SyncFIFO streams (in sys_clk domain)
    // -------------------------------------------

    wire [7:0] sys_ft_rx_data;
    wire sys_ft_rx_valid;
    wire sys_ft_rx_ready;
    wire [7:0] sys_ft_tx_data;
    wire sys_ft_tx_valid;
    wire sys_ft_tx_ready;

    // ------------------------
    // Wishbone bus
    // ------------------------

    localparam WB_ADDR_WIDTH = 8;

    // Wishbone master - control port - bus
    wire wbm_cp_cyc;
    wire wbm_cp_stb;
    wire wbm_cp_stall;
    wire wbm_cp_ack;
    wire wbm_cp_we;
    wire [WB_ADDR_WIDTH-1:0] wbm_cp_addr;
    wire [31:0] wbm_cp_wdata;
    wire [3:0] wbm_cp_sel;
    wire [31:0] wbm_cp_rdata;

    // ------------------------
    // Wishbone master: control port
    // ------------------------
    wb_ctrl_port #(
        .WB_ADDR_WIDTH(WB_ADDR_WIDTH),
        .NUM_EMREQS(1)
    ) wb_ctrl_port_i (
        .i_clk(sys_clk),
        .i_rst(sys_rst),
        // status
        // .o_err_crc(err_crc),
        // wb
        .o_wb_cyc(wbm_cp_cyc),
        .o_wb_stb(wbm_cp_stb),
        .i_wb_stall(wbm_cp_stall),
        .i_wb_ack(wbm_cp_ack),
        .o_wb_we(wbm_cp_we),
        .o_wb_addr(wbm_cp_addr),
        .o_wb_data(wbm_cp_wdata),
        .o_wb_sel(wbm_cp_sel),
        .i_wb_data(wbm_cp_rdata),
        // rx
        .o_rx_ready(sys_ft_rx_ready),
        .i_rx_data(sys_ft_rx_data),
        .i_rx_valid(sys_ft_rx_valid),
        // tx
        .i_tx_ready(sys_ft_tx_ready),
        .o_tx_data(sys_ft_tx_data),
        .o_tx_valid(sys_ft_tx_valid),
        // TODO: EMREQs
        .i_emreqs_valid(adc1_emreq_valid),
        .o_emreqs_ready(adc1_emreq_ready),
        .i_emreqs(pack_mreq(8'h01, 1'b0, 1'b0, MREQ_WFMT_32S0, 8'hFF, 24'h000080))
    );

    // --------------------------------------
    // Control and status registers
    // --------------------------------------

    lwdo_regs #(
        .ADDRESS_WIDTH(WB_ADDR_WIDTH+2),
        .DEFAULT_READ_DATA(32'hDEADBEEF)
    ) lwdo_regs_i (
        // SYSCON
        .i_clk(sys_clk),
        .i_rst_n(~sys_rst),

        // WISHBONE
        .i_wb_cyc(wbm_cp_cyc),
        .i_wb_stb(wbm_cp_stb),
        .o_wb_stall(wbm_cp_stall),
        .i_wb_adr({wbm_cp_addr, 2'b0}),
        .i_wb_we(wbm_cp_we),
        .i_wb_dat(wbm_cp_wdata),
        .i_wb_sel(wbm_cp_sel),
        .o_wb_ack(wbm_cp_ack),
        .o_wb_dat(wbm_cp_rdata),

        // REGS: SYS
        .o_sys_con_sys_rst(sys_rst_req),
        // REGS: ADCT
        .o_adct_con_srate1_en(csr_adct_srate1_en),
        .o_adct_con_srate2_en(csr_adct_srate2_en),
        .o_adct_con_puls1_en(csr_adct_puls1_en),
        .o_adct_con_puls2_en(csr_adct_puls2_en),
        .o_adct_srate1_psc_div_val(csr_adct_srate1_psc_div),
        .o_adct_srate2_psc_div_val(csr_adct_srate2_psc_div),
        .o_adct_puls1_psc_div_val(csr_adct_puls1_psc_div),
        .o_adct_puls2_psc_div_val(csr_adct_puls2_psc_div),
        .o_adct_puls1_dly_val(csr_adct_puls1_dly),
        .o_adct_puls2_dly_val(csr_adct_puls2_dly),
        .o_adct_puls1_pwidth_val(csr_adct_puls1_pwidth),
        .o_adct_puls2_pwidth_val(csr_adct_puls2_pwidth),
        // REGS: ADC1
        .i_adc_fifo1_sts_empty(adc1_fifo_empty),
        .i_adc_fifo1_sts_full(adc1_fifo_full),
        .i_adc_fifo1_sts_hfull(adc1_fifo_hfull),
        .i_adc_fifo1_sts_ovfl(adc1_fifo_ovfl_lval),
        .o_adc_fifo1_sts_ovfl_read_trigger(adc1_fifo_ovfl_lclr),
        .i_adc_fifo1_sts_udfl(adc1_fifo_udfl_lval),
        .o_adc_fifo1_sts_udfl_read_trigger(adc1_fifo_udfl_lclr),
        .i_adc_fifo1_port_data(adc1_fifo_data),
        .o_adc_fifo1_port_data_read_trigger(adc1_fifo_rd),
        // REGS: ADC2
        .i_adc_fifo2_sts_empty(adc2_fifo_empty),
        .i_adc_fifo2_sts_full(adc2_fifo_full),
        .i_adc_fifo2_sts_hfull(adc2_fifo_hfull),
        .i_adc_fifo2_sts_ovfl(adc2_fifo_ovfl_lval),
        .o_adc_fifo2_sts_ovfl_read_trigger(adc2_fifo_ovfl_lclr),
        .i_adc_fifo2_sts_udfl(adc2_fifo_udfl_lval),
        .o_adc_fifo2_sts_udfl_read_trigger(adc2_fifo_udfl_lclr),
        .i_adc_fifo2_port_data(adc2_fifo_data),
        .o_adc_fifo2_port_data_read_trigger(adc2_fifo_rd),
        // REGS: FTUN
        .o_ftun_vtune_set_val(csr_ftun_vtune_val),
        .o_ftun_vtune_set_val_write_trigger(csr_ftun_vtune_write)
    );

    // ===============================================================================================================
    // =========================                                                             =========================
    // =========================                   FTDI SyncFIFO CLOCK DOMAIN                =========================
    // =========================                       @(posedge ft_clk)                     =========================
    // =========================                                                             =========================
    // ===============================================================================================================

    // Clock is generated by FT(2)232H itself. Clock is available only when FT232H is switched to
    // SyncFIFO mode and not in reset. Thus, FPGA must account for the fact that this clock domain
    // is NOT always running when the other FPGA clocks are running

    wire ft_clk;

    // ----------------------------
    // FTDI domain reset generator
    // ----------------------------

    // Reset asserted on:
    //  - FPGA reconfiguration (power on)
    //  - Asynchronously when ft_rst_req goes high
    // Reset deasserted on:
    //  - First ft_clk cycle when ft_rst_req is low
    reg ft_rst = 1'b1;
    wire ft_rst_req;

    // Asynchronously assert FT reset when sys_rst is asserted
    assign ft_rst_req = sys_rst;

    always @(posedge ft_clk or posedge ft_rst_req) begin
        ft_rst <= 1'b0;
        if (ft_rst_req) begin
            ft_rst <= 1'b1;
        end
    end

    // ------------------------
    // FTDI SyncFIFO bidirectional data bus
    // ------------------------
    wire [7:0] ft_fifo_d_in;
    wire [7:0] ft_fifo_d_out;
    wire ft_fifo_d_oe;

    SB_IO #(
        .PIN_TYPE(6'b 1010_01)
    ) ft_fifo_data_pins [7:0] (
        .PACKAGE_PIN(p_ft_fifo_d),
        .OUTPUT_ENABLE(ft_fifo_d_oe),
        .D_OUT_0(ft_fifo_d_out),
        .D_IN_0(ft_fifo_d_in)
    );

    // ------------------------
    // FTDI SyncFIFO port
    // ------------------------

    // Side A:
    //      FT(2)232H SyncFIFO bus
    // Side B:
    //      Data-ready-valid Rx & Tx byte streams

    wire [7:0] ft_tx_data;
    wire ft_tx_valid;
    wire ft_tx_ready;
    wire [7:0] ft_rx_data;
    wire ft_rx_valid;
    wire ft_rx_ready;
    wire [3:0] ft_dbg;

    ft245sync ft245sync_i (
        // SYSCON
        .o_clk(ft_clk),
        .i_rst(ft_rst),
        // pins
        .i_pin_clkout(p_ft_fifo_clkout),
        .o_pin_oe_n(p_ft_fifo_oe_n),
        .o_pin_siwu(p_ft_fifo_siwu),
        .o_pin_wr_n(p_ft_fifo_wr_n),
        .o_pin_rd_n(p_ft_fifo_rd_n),
        .i_pin_rxf_n(p_ft_fifo_rxf_n),
        .i_pin_txe_n(p_ft_fifo_txe_n),
        .i_pin_data(ft_fifo_d_in),
        .o_pin_data(ft_fifo_d_out),
        .o_pin_data_oe(ft_fifo_d_oe),
        // Streams
        .i_tx_data(ft_tx_data),
        .i_tx_valid(ft_tx_valid),
        .o_tx_ready(ft_tx_ready),
        .o_rx_data(ft_rx_data),
        .o_rx_valid(ft_rx_valid),
        .i_rx_ready(ft_rx_ready),
        // debug
        .o_dbg(ft_dbg)
    );

    // ===============================================================================================================
    // =========================                                                             =========================
    // =========================                    CLOCK DOMAIN CROSSING                    =========================
    // =========================            @(posedge sys_clk) / @(posedge ft_clk)           =========================
    // =========================                                                             =========================
    // ===============================================================================================================

    // FIFO size: 256 bytes. That's half of ICE40 4K BRAM, but it improves timing compared to 512.
    localparam FT_AFIFO_ASIZE = 8;

    // Two asynchronous FIFOs: one for Rx stream, one for Tx stream
    // NOTE: resets here are asynchronous assert, synchronous release

    // ft_clk domain
    wire ft_afifo_rx_wfull;
    wire ft_afifo_tx_rempty;
    assign ft_rx_ready = !ft_afifo_rx_wfull;
    assign ft_tx_valid = !ft_afifo_tx_rempty;
    // sys_clk domain
    wire ft_afifo_rx_rempty;
    wire ft_afifo_tx_wfull;
    assign sys_ft_rx_valid = !ft_afifo_rx_rempty;
    assign sys_ft_tx_ready = !ft_afifo_tx_wfull;

    async_fifo #(
        .DSIZE(8),
        .ASIZE(FT_AFIFO_ASIZE),
        .FALLTHROUGH("FALSE")
    ) ft_afifo_rx (
        //
        .wclk(ft_clk),
        .wrst_n(!ft_rst),
        //
        .winc(ft_rx_valid && ft_rx_ready),
        .wdata(ft_rx_data),
        .wfull(ft_afifo_rx_wfull),
        //
        .rclk(sys_clk),
        .rrst_n(!sys_rst),
        //
        .rinc(sys_ft_rx_valid && sys_ft_rx_ready),
        .rdata(sys_ft_rx_data),
        .rempty(ft_afifo_rx_rempty)
    );

    async_fifo #(
        .DSIZE(8),
        .ASIZE(FT_AFIFO_ASIZE),
        .FALLTHROUGH("FALSE")
    ) ft_afifo_tx (
        //
        .wclk(sys_clk),
        .wrst_n(!sys_rst),
        //
        .winc(sys_ft_tx_valid && sys_ft_tx_ready),
        .wdata(sys_ft_tx_data),
        .wfull(ft_afifo_tx_wfull),
        //
        .rclk(ft_clk),
        .rrst_n(!ft_rst),
        //
        .rinc(ft_tx_valid && ft_tx_ready),
        .rdata(ft_tx_data),
        .rempty(ft_afifo_tx_rempty)
    );

    // ===============================================================================================================
    // =========================                                                             =========================
    // =========================                    OUTPUT PIN DRIVERS                       =========================
    // =========================                                                             =========================
    // ===============================================================================================================

    // ------------------------
    // CLK OUT
    // ------------------------
    assign p_clk_out_sel = 1'b1;
    assign p_clk_out = ~adc1_fifo_full;

    // ------------------------
    // LEDs
    // ------------------------
    assign p_led_sts_r = ft_dbg[0];
    assign p_led_sts_g = ft_dbg[1];
    //
    assign p_led_in1_r = ft_tx_valid;   // 0
    assign p_led_in1_g = ft_tx_ready;   // 1
    assign p_led_in2_r = ft_rx_valid;   // 1
    assign p_led_in2_g = ft_rx_ready;   // 0
    // assign p_led_in3_r = ~p_ft_fifo_rxf_n;
    // assign p_led_in3_g = 0;
    // assign p_led_in4_r = ~p_ft_fifo_txe_n;
    // assign p_led_in4_g = 0;
    assign p_led_in3_r = adc1_emreq_valid;
    assign p_led_in3_g = adct_puls1_w;
    assign p_led_in4_r = adc1_emreq_ready;
    assign p_led_in4_g = adct_puls2_w;


endmodule
