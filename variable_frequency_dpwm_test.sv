// ============================================================
// Module:
//     variable_frequency_dpwm_test
//
// Board:
//     DE25-Standard
//
// PLL:
//     Input  : 50 MHz
//     Output : 100 MHz, four phases
//
// GPIO:
//     GPIO[0] = DPWM output
//     GPIO[1] = PLL clock 0 degrees
//     GPIO[2] = PLL clock 90 degrees
//     GPIO[3] = PLL clock 180 degrees
//     GPIO[4] = PLL clock 270 degrees
//
// Automatic test sequence:
//     State 00: 500 kHz, falling edge phase = 0
//     State 01: 500 kHz, falling edge phase = 270
//     State 10:   1 MHz, falling edge phase = 0
//     State 11:   1 MHz, falling edge phase = 270
//
// Each state now lasts PERIODS_PER_STATE complete DPWM periods
// (not a fixed time), so 500 kHz and 1 MHz show the same number
// of periods on a logic analyzer.
// ============================================================

module variable_frequency_dpwm_test (
    input  wire       CLOCK_50,

    output wire       LEDR0,
    output wire       LEDR1,
    output wire       LEDR2,

    output wire [4:0] GPIO
);


    // ========================================================
    // PLL output clocks
    // ========================================================

    logic clk_100m_0;
    logic clk_100m_90;
    logic clk_100m_180;
    logic clk_100m_270;

    logic pll_locked;


    // ========================================================
    // IOPLL
    //
    // outclk_0 = 100 MHz,   0
    // outclk_1 = 100 MHz,  90
    // outclk_2 = 100 MHz, 180
    // outclk_3 = 100 MHz, 270
    // ========================================================

    pll_4phase u_pll_4phase (
        .refclk   (CLOCK_50),
        .rst      (1'b0),

        .outclk_0 (clk_100m_0),
        .outclk_1 (clk_100m_90),
        .outclk_2 (clk_100m_180),
        .outclk_3 (clk_100m_270),

        .locked   (pll_locked)
    );


    // ========================================================
    // PLL lock synchronizer
    //
    // Wait two clk_100m_0 cycles after PLL lock before starting.
    // ========================================================

    logic [1:0] lock_pipe;
    wire        run_enable;

    always_ff @(posedge clk_100m_0 or negedge pll_locked) begin
        if (!pll_locked) begin
            lock_pipe <= 2'b00;
        end
        else begin
            lock_pipe <= {lock_pipe[0], 1'b1};
        end
    end

    assign run_enable = lock_pipe[1];


    // ========================================================
    // Mode timing (period-based)
    //
    // Each test state lasts a fixed number of COMPLETE DPWM
    // periods. Advancing the state at a period boundary is
    // inherently glitch-free (the current pulse is never cut).
    //
    // Full sequence length on the LA:
    //   500 kHz : 2000 ns/period * 8 = 16 us  (states 00, 01)
    //   1 MHz   : 1000 ns/period * 8 =  8 us  (states 10, 11)
    //   total   : 16 + 16 + 8 + 8   = 48 us  -> ~9600 samples @ 200 MS/s
    //
    // Tune PERIODS_PER_STATE to trade capture length vs. how
    // many periods you see per state.
    // ========================================================

    localparam int unsigned PERIODS_PER_STATE = 8;

    // Active mode drives the whole datapath. It only changes at a
    // DPWM period boundary, so no separate requested/active split
    // is needed anymore.
    logic [1:0] active_mode;


    // ========================================================
    // Dynamic frequency parameters
    //
    // At PLL clock = 100 MHz:
    //   500 kHz -> 100 MHz / 500 kHz = 200 clocks
    //   1 MHz   -> 100 MHz / 1 MHz   = 100 clocks
    // ========================================================

    localparam logic [15:0] PERIOD_500KHZ = 16'd200;
    localparam logic [15:0] PERIOD_1MHZ   = 16'd100;

    logic [15:0] period_ticks;
    logic [15:0] half_ticks;

    // 00 = 0, 01 = 90, 10 = 180, 11 = 270
    logic [1:0] fall_phase;


    // ========================================================
    // Decode current active mode
    // ========================================================

    always_comb begin

        // Default values
        period_ticks = PERIOD_500KHZ;
        fall_phase   = 2'd0;

        case (active_mode)

            // 500 kHz, falling edge at phase 0
            2'b00: begin
                period_ticks = PERIOD_500KHZ;
                fall_phase   = 2'd0;
            end

            // 500 kHz, falling edge delayed to phase 270
            2'b01: begin
                period_ticks = PERIOD_500KHZ;
                fall_phase   = 2'd3;
            end

            // 1 MHz, falling edge at phase 0
            2'b10: begin
                period_ticks = PERIOD_1MHZ;
                fall_phase   = 2'd0;
            end

            // 1 MHz, falling edge delayed to phase 270
            2'b11: begin
                period_ticks = PERIOD_1MHZ;
                fall_phase   = 2'd3;
            end

            default: begin
                period_ticks = PERIOD_500KHZ;
                fall_phase   = 2'd0;
            end

        endcase

        // 50% coarse duty location
        half_ticks = period_ticks >> 1;

    end


    // ========================================================
    // Coarse period counter + period-based mode advance
    // ========================================================

    logic [15:0] period_counter;
    logic [7:0]  period_in_state;   // completed DPWM periods in current state


    always_ff @(posedge clk_100m_0 or negedge pll_locked) begin

        if (!pll_locked) begin

            active_mode     <= 2'b00;
            period_counter  <= 16'd0;
            period_in_state <= 8'd0;

        end
        else if (!run_enable) begin

            active_mode     <= 2'b00;
            period_counter  <= 16'd0;
            period_in_state <= 8'd0;

        end
        else begin

            // =================================================
            // DPWM period counter
            //
            // On every completed period, count it; after
            // PERIODS_PER_STATE periods, advance the test mode.
            // Both happen exactly at the period boundary.
            // =================================================

            if (period_counter >= period_ticks - 16'd1) begin

                period_counter <= 16'd0;

                if (period_in_state >= PERIODS_PER_STATE - 1) begin
                    period_in_state <= 8'd0;
                    active_mode     <= active_mode + 2'd1;  // 00->01->10->11->00
                end
                else begin
                    period_in_state <= period_in_state + 8'd1;
                end

            end
            else begin

                period_counter <= period_counter + 16'd1;

            end

        end

    end


    // ========================================================
    // Fine phase timing
    //
    // During the single coarse interval where
    // period_counter == half_ticks, the selected PLL phase
    // decides when the output falls.
    //
    //   TPLL = 10 ns
    //   phase 0   = 0.0 ns
    //   phase 90  = 2.5 ns
    //   phase 180 = 5.0 ns
    //   phase 270 = 7.5 ns
    //
    // fine_hold stays high until the selected phase edge.
    // ========================================================

    logic fine_hold;

    always_comb begin

        case (fall_phase)

            // Fall immediately at clk_100m_0 rising edge
            2'd0: begin
                fine_hold = 1'b0;
            end

            // Remain high from 0 to 90
            2'd1: begin
                fine_hold = clk_100m_0 && !clk_100m_90;
            end

            // Remain high from 0 to 180
            2'd2: begin
                fine_hold = clk_100m_0;
            end

            // Remain high from 0 to 270
            2'd3: begin
                fine_hold = clk_100m_0 || !clk_100m_270;
            end

            default: begin
                fine_hold = 1'b0;
            end

        endcase

    end


    // ========================================================
    // Final DPWM output
    //
    // Rising edge : period_counter returns to zero at clk_100m_0.
    // Falling edge: coarse counter reaches half_ticks, then the
    //               selected phase produces the fine delay.
    // ========================================================

    logic dpwm_output;

    always_comb begin

        dpwm_output = 1'b0;

        if (run_enable) begin

            // Coarse high interval
            if (period_counter < half_ticks) begin
                dpwm_output = 1'b1;
            end

            // Fine phase interval (single 10 ns window)
            else if (period_counter == half_ticks) begin
                dpwm_output = fine_hold;
            end

            // Remaining part of the DPWM period
            else begin
                dpwm_output = 1'b0;
            end

        end

    end


    // ========================================================
    // GPIO outputs
    // ========================================================

    assign GPIO[0] = dpwm_output;   // final DPWM

    assign GPIO[1] = clk_100m_0;    // four PLL phases (scope reference)
    assign GPIO[2] = clk_100m_90;
    assign GPIO[3] = clk_100m_180;
    assign GPIO[4] = clk_100m_270;


    // ========================================================
    // Active-low LEDs
    // ========================================================

    assign LEDR0 = !pll_locked;       // ON = PLL locked
    assign LEDR1 = !active_mode[1];   // ON = 1 MHz
    assign LEDR2 = !active_mode[0];   // ON = falling phase 270


endmodule