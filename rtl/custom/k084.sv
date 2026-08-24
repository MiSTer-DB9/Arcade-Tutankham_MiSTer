//============================================================================
//
//  SystemVerilog implementation of the Konami 084 custom chip, the starfield
//  generator (plus watchdog timer) used on the Tutankham KT-3203-1B PCB.
//
//  Reconstructed from the 084 pinout, the Galaxian/Scramble star circuit that
//  MAME models in tutankhm_v.cpp, and the Konami bootleg daughter-board that
//  replaced this chip.
//
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  DEALINGS IN THE SOFTWARE.
//
//============================================================================

//Chip pinout, confirmed against the Stern Tutankham service manual, C.R.T. Board
//schematic 34D-0126-S, where the part is labelled "084 / F3".  That sheet also
//corrects two details of the pinout circulated with MAME: pin 12 is a second
//ground alongside pin 11, and pin 9 is not connected.
/*                _____________
                _|             |_
NE555 ~1Hz     |_|10         24|_| VCC
                _|             |_
18MHz    (401) |_|1          19|_| Reset Enable (419)
                _|             |_
6MHz     (109) |_|2          20|_| 0x8120 watchdog kick (420)
                _|             |_
256H*    (403) |_|3          21|_| V2  (421)
                _|             |_
VBlank*  (404) |_|4          22|_| V1  (422)
                _|             |_
/SYNC*   (405) |_|5          23|_| H8Q (423)
                _|             |_
Aux En   (406) |_|6          18|_| Blue  (100 ohm, MSB)
                _|             |_
Stars En (407) |_|7          17|_| Blue  (150 ohm, LSB)
                _|             |_
Horz Flip (HFF)|_|8          16|_| Green (100 ohm, MSB)
                _|             |_
GND      (11,12)|_|11        15|_| Green (150 ohm, LSB)
                _|             |_
               |_|           14|_| Red   (100 ohm, MSB)
                _|             |_
               |_|           13|_| Red   (150 ohm, LSB)
                 |_____________|
*/

//----------------------------------------------------------------------------
// How the chip works
//----------------------------------------------------------------------------
//
// The 084 is the Galaxian/Scramble star generator collapsed into one package.
// Every documented pin is accounted for by that circuit:
//
//   * A free-running 17-bit LFSR is clocked by (18MHz AND 6MHz).  The 6MHz
//     pixel clock is produced by a divide-by-3 with a 2/3 duty cycle, so the
//     AND yields TWO LFSR clocks per pixel, unevenly spaced: the first result
//     is valid for 1/3 of a pixel, the second for the remaining 2/3.
//   * Pins 3 and 4 (256H*, VBlank*) gate that clock so the LFSR only advances
//     across the 256 visible pixels of each visible line - exactly 512 steps
//     per line.  VBlank also clears it, which is why the pattern is static
//     from frame to frame (Tutankham never scrolls its star origin).
//   * A star exists when the top 8 bits of the LFSR are all 1 and the bit
//     leaving the register is 0.  The 6 bits below the top 8, inverted, are
//     the star colour: 2 bits each of R, G and B driving 150 ohm (LSB) and
//     100 ohm (MSB) resistors into the video summing node (pins 13-18).
//   * Pin 10's NE555 (Ra=100k, Rb=10k, C=10uF => ~1.2Hz) clocks a 2-bit blink
//     counter.  Its four states gate the stars with: always on, V1, V2, H8Q -
//     which is precisely why V1, V2 and H8Q are pins 22, 21 and 23.
//   * V1 XOR H8Q additionally dithers the field so only half the pixel grid
//     can ever hold a star.
//   * Pins 19/20 are unrelated to video: they are the watchdog.  A read of
//     0x8120 pulses pin 20 and pin 19 drives the board reset circuit.
//
// Two deductions worth calling out, because they differ from MAME:
//
//   1. The 084 has NO H64 or H128 input.  MAME's tutankhm star code inherits
//      `((x & 0xc0) ^ flipxor) != 0xc0` from galaxian.cpp, suppressing stars
//      in one quarter of the line.  This chip physically cannot see those
//      counter bits, so that term is not modelled here.  Set SUPPRESS_C0 to
//      re-enable it for A/B comparison.
//   2. Pin 6 "Aux Enable" is the per-pixel video gate.  The bootleg board that
//      replaced the 084 gates stars on framebuffer bit 1 being clear
//      (`BIT(~shifted, 1)` in MAME), not on the pixel being colour 0, so a
//      star shows through eight of the sixteen palette indices.  Drive pin 6
//      accordingly - see the instantiation in Tutankham_CPU.sv.
//
// What sheet 34D-0126-S adds, beyond confirming the block above:
//
//   * Pin 3 is 082 pin 10, which is /H256 - so the RNG window is the 256 counts
//     where the horizontal counter's bit 8 is set, not a general HBlank.  That
//     is where the 512 steps per line come from, and it pins down WHICH 256
//     pixels carry stars rather than merely how many.
//   * Pin 4 is 082 pin 15 (/VBlank) and pin 5 is 082 pin 18 (/VSync).  Pin 5 is
//     a sync blank, not a full video blank.
//   * Pin 23 is the output of an LS86 at F11 whose other input is BHFF, the
//     buffered horizontal flip.  H8Q therefore arrives ALREADY flipped, so this
//     model must not XOR it with pin 8 again.  What pin 8 does inside the chip
//     is then unresolved: with H8Q pre-flipped and no H64/H128 to suppress, it
//     has no remaining job that the rest of the pinout can account for.
//   * Pin 6 comes from a chain of AND gates at E8 whose inputs include net 315
//     from the 083 at B5.  The 083 sits on the same 16 lines as the framebuffer
//     DRAM data bus and the LS373 video latches, which is direct support for
//     Aux Enable being framebuffer-derived - though the 083 is itself a custom,
//     so the drawing cannot prove which bit.
//   * Each star output pair drives 100 ohm (MSB) and 150 ohm (LSB) into a node
//     with 470 ohm to ground, hard-wired onto the palette ladder with no gate
//     between.  Star and palette current simply sum.
//   * Pins 19/20 are confirmed: pin 20 is LS138 D5 Y2, decoding 0x8120, and pin
//     19 sources into the RESET chain.  Note the reset PULSE is shaped by a
//     second NE555 at F0 - the 084 supplies the expiry, not the timing.
//
// Host-clock notes: `clk` is the 49.152MHz core clock and `cen_6m` is the
// existing one-in-eight pixel enable.  18.432MHz is 3/8 of 49.152MHz, so the
// three master ticks inside a pixel land on host cycles 0, 3 and 5; the two
// LFSR clocks are the first two of those.  Star output is registered and
// presented one pixel later, matching the framebuffer read latency in the
// parent module.

module k084 #(
	//Host clock cycles per ~1.2Hz NE555 period (49.152MHz * 0.8316s)
	parameter [25:0] BLINK_DIV   = 26'd40874803,
	//Host clock cycles before the watchdog fires when never kicked (~1s)
	parameter [25:0] WD_TIMEOUT  = 26'd49152000,
	//Set to 1 to reinstate MAME's galaxian-inherited x[7:6]==2'b11 suppression
	parameter        SUPPRESS_C0 = 1'b0,
	//How pin 4 clears the LFSR - see the note above the LFSR below
	parameter        VB_LEVEL_CLEAR = 1'b1
)
(
	input        clk,           //49.152MHz host clock (not a real pin)
	input        reset,         //Active low (not a real pin)
	input        cen_6m,        //pin 2  - 6.144MHz pixel clock enable
	input        hblank,        //pin 3  - /H256 from 082 pin 10, active high
	input        vblank,        //pin 4  - /VBlank from 082 pin 15, active high
	input        blank,         //pin 5  - /VSync from 082 pin 18, active high
	input        aux_en,        //pin 6  - Aux Enable, per-pixel video gate
	input        stars_en,      //pin 7  - Stars Enable, from LS259 C3 Q4
	input        hff,           //pin 8  - Horizontal flip from LS259 C3 Q6.
	                            //         Role inside the chip unresolved: H8Q
	                            //         already arrives flipped, so this is
	                            //         only read when SUPPRESS_C0 is set.
	input        h8q,           //pin 23 - LS86 F11 output, inverted and pre-flipped
	input        v1,            //pin 22 - V1 from 085 D9 pin 18
	input        v2,            //pin 21 - V2 from 085 D9 pin 17
	input  [1:0] hpos_hi,       //x[7:6], only used when SUPPRESS_C0 = 1
	input        wd_kick,       //pin 20 - pulses on a read of 0x8120
	input        bootleg_mode,  //Selects the daughter-board LFSR tap phase

	output [1:0] star_r,        //pins 14/13 - Red   {100 ohm, 150 ohm}
	output [1:0] star_g,        //pins 16/15 - Green {100 ohm, 150 ohm}
	output [1:0] star_b,        //pins 18/17 - Blue  {100 ohm, 150 ohm}
	output       star_on,       //High when this pixel carries a star
	output reg   wd_reset = 0   //pin 19 - Reset Enable, active high
);

//--------------------------------------------------------- RNG clocking ---------------------------------------------------------//

//Track position within the current pixel so the second LFSR clock can be placed
//where the real 18MHz master tick falls (host cycle 3 of 8).
reg [2:0] phase = 3'd0;
always_ff @(posedge clk) begin
	if(cen_6m)
		phase <= 3'd1;
	else
		phase <= phase + 3'd1;
end

//The two LFSR clocks inside one pixel: the first covers 1/3 of the pixel, the
//second covers the remaining 2/3.
wire rng_cen_a = cen_6m;
wire rng_cen_b = (phase == 3'd3);

//Pin 3 gates the LFSR to the 256 visible pixels of a line - 512 steps per line,
//which is exactly MAME's stars_draw_row(..., star_offs = y * 512).
wire capture_run = ~hblank & ~vblank;

//Pin 4's precise effect on the LFSR is the one thing the pinout cannot settle.
//A level-sensitive clear (VB_LEVEL_CLEAR = 1, and the simplest silicon) holds
//the register at zero for the whole of VBlank, so the pattern starts at step 0
//on the first visible line.  An edge-triggered clear (VB_LEVEL_CLEAR = 0) zeroes
//it once as VBlank begins and lets it keep running through the blanked lines,
//which is closer to what MAME's y*512 offsets assume - MAME's y counts from the
//top of the 264-line frame, so its first visible line is already 16*512 steps in.
//Both choices give the same star density and the same colour distribution; only
//the positions move.  Telling them apart needs a die shot or a capture from a
//real board, so this is left as a parameter rather than guessed at.
reg vblank_d = 0;
always_ff @(posedge clk) begin
	if(cen_6m)
		vblank_d <= vblank;
end
wire vblank_start = vblank & ~vblank_d;

wire lfsr_clear = VB_LEVEL_CLEAR ? vblank : vblank_start;
wire rng_run    = ~hblank & (VB_LEVEL_CLEAR ? ~vblank : 1'b1);

//------------------------------------------------------------ LFSR ------------------------------------------------------------//

//17-bit right-shifting LFSR, XNOR feedback from bits 12 and 0 into bit 16.
//Period is 2^17-1; all-ones is the lock-up state, so clearing to 0 is safe.
reg [16:0] lfsr = 17'd0;
wire feedback = lfsr[12] ^ ~lfsr[0];

always_ff @(posedge clk) begin
	if(!reset || lfsr_clear)
		lfsr <= 17'd0;
	else if(rng_run && (rng_cen_a || rng_cen_b))
		lfsr <= {feedback, lfsr[16:1]};
end

//A star exists when the top 8 bits are all set and the bit leaving the register
//is 0.  The bootleg daughter-board tests the bit ENTERING the register instead,
//which shifts the whole field by one RNG step.
wire star_hit = (lfsr[16:9] == 8'hFF) & (bootleg_mode ? ~feedback : ~lfsr[0]);

//Colour is the six bits below the top eight, inverted.  Bit numbering follows
//MAME's star palette: [5]/[4] red, [3]/[2] green, [1]/[0] blue, with the even
//index of each pair driving the 100 ohm (brighter) resistor.
wire [5:0] star_col = ~lfsr[8:3];

//--------------------------------------------------------- Pixel capture --------------------------------------------------------//

//Sample the LFSR at both clock positions in the pixel, then present the result
//during the following pixel so the output is stable for a whole pixel time.
reg       hit_a = 0, hit_b = 0;
reg [5:0] col_a = 6'd0, col_b = 6'd0;
reg       pix_hit = 0;
reg [5:0] pix_col = 6'd0;

always_ff @(posedge clk) begin
	if(!reset) begin
		hit_a <= 0; hit_b <= 0;
		col_a <= 6'd0; col_b <= 6'd0;
		pix_hit <= 0; pix_col <= 6'd0;
	end
	else begin
		//Latch the previous pixel's samples for display.  The second sample
		//covers 2/3 of the pixel, so it wins when both carry a star.
		if(cen_6m) begin
			pix_hit <= hit_a | hit_b;
			pix_col <= hit_b ? col_b : col_a;
			hit_a <= 0;
			hit_b <= 0;
		end

		if(capture_run && rng_cen_a) begin
			hit_a <= star_hit;
			col_a <= star_col;
		end
		if(capture_run && rng_cen_b) begin
			hit_b <= star_hit;
			col_b <= star_col;
		end
	end
end

//---------------------------------------------------------- Blink counter -------------------------------------------------------//

//NE555 astable on pin 10: Ra=100k, Rb=10k, C=10uF gives 0.693*(Ra+2*Rb)*C
//= 0.8316s (~1.2Hz).  It clocks a free-running 2-bit counter.
reg [25:0] blink_div = 26'd0;
reg  [1:0] blink_state = 2'd0;
always_ff @(posedge clk) begin
	if(!reset) begin
		blink_div <= 26'd0;
		blink_state <= 2'd0;
	end
	else if(blink_div == BLINK_DIV) begin
		blink_div <= 26'd0;
		blink_state <= blink_state + 2'd1;
	end
	else
		blink_div <= blink_div + 26'd1;
end

//--------------------------------------------------------- Display gating -------------------------------------------------------//

//H8Q arrives inverted (MAME: h8q = BIT(~x, 3)) and, per sheet 34D-0126-S,
//already XORed with the buffered flip signal by the LS86 at F11.  It is used
//as-is here; XORing pin 8 in again would flip the field twice.
wire blink_enab = (blink_state == 2'd0) ? 1'b1 :
                  (blink_state == 2'd1) ? v1   :
                  (blink_state == 2'd2) ? v2   :
                                          h8q;

//V1 XOR H8Q dithers the field so only half the pixel grid can hold a star.
wire dither = v1 ^ h8q;

//MAME's galaxian-inherited quarter-line suppression.  The 084 has no H64/H128
//pin, so this is off by default - see the header notes.
wire c0_ok = (SUPPRESS_C0 == 1'b0) | ((hpos_hi ^ {2{hff}}) != 2'b11);

assign star_on = pix_hit & stars_en & aux_en & dither & blink_enab & c0_ok & ~blank;

//Outputs are {100 ohm, 150 ohm} per channel.
assign star_r = star_on ? {pix_col[4], pix_col[5]} : 2'b00;
assign star_g = star_on ? {pix_col[2], pix_col[3]} : 2'b00;
assign star_b = star_on ? {pix_col[0], pix_col[1]} : 2'b00;

//----------------------------------------------------------- Watchdog -----------------------------------------------------------//

//Pin 20 is pulsed by a read of 0x8120; pin 19 drives the board reset circuit
//once the counter expires.  Modelled for completeness - see Tutankham_CPU.sv
//for why the output is currently left unconnected.
reg [25:0] wd_count = 26'd0;
always_ff @(posedge clk) begin
	if(!reset) begin
		wd_count <= 26'd0;
		wd_reset <= 0;
	end
	else if(wd_kick) begin
		wd_count <= 26'd0;
		wd_reset <= 0;
	end
	else if(wd_count == WD_TIMEOUT) begin
		wd_count <= 26'd0;
		wd_reset <= 1;
	end
	else begin
		wd_count <= wd_count + 26'd1;
		wd_reset <= 0;
	end
end

endmodule
