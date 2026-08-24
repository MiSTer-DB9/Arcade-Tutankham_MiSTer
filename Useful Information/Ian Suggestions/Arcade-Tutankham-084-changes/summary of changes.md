# Konami 084 starfield — summary of changes

**Project:** Arcade-Tutankham (MiSTer core)
**Date:** 24 August 2026

Replaces the placeholder Moon Cresta starfield with a reconstruction of the Konami 084
custom chip, reverse engineered from its pinout, MAME's Galaxian-family star code, and
Stern's C.R.T. board schematic.

---

## Files in this archive

Paths are relative to the project root, so the archive can be unpacked straight over a
clean checkout. `removed/` and `tools/` are not part of the build.

| Path | Status | Change |
|---|---|---|
| `rtl/custom/k084.sv` | **new** | The 084 model — starfield generator plus watchdog timer |
| `rtl/custom/tut_custom.qip` | modified | Registers `k084.sv` with the build |
| `rtl/Tutankham_CPU.sv` | modified | Instantiates `k084`; rewritten star/palette video mixing |
| `files.qip` | modified | Dropped the `rtl/mc_stars.vhd` entry |
| `rtl/mc_stars.vhd` | **deleted** | Copy kept in `removed/` for reference only |
| `tools/verify_k084.py` | reference | Re-runs the MAME cross-check; not part of the build |

---

## What the 084 turned out to be

The Galaxian/Scramble starfield generator collapsed into a single package, with the
board's watchdog riding along on two spare pins.

Two pins settle it. Pin 1 takes the 18.432 MHz master clock and pin 2 the 6.144 MHz pixel
clock — and the only circuit that wants both is the one at the heart of that starfield: the
pixel clock is a divide-by-three with a 2/3 duty cycle, so ANDing them yields two unevenly
spaced RNG clocks inside every pixel, the first covering a third of it and the second the
rest. Nothing else on the board needs that pair of frequencies together.

Everything else follows. A 17-bit LFSR with XNOR feedback from bits 12 and 0 is clocked by
that AND and gated by pins 3 and 4 to exactly 512 steps per line. A star exists where the
top eight bits are all set and the bit leaving the register is zero; the six bits beneath,
inverted, are its colour. V1 and V2 are pins because the NE555 blink counter selects
between them; H8Q is a pin because it dithers the field and drives the fourth blink state.

### Pin sources, as traced on sheet 34D-0126-S

| Pin | Net | Signal | Driven by |
|---|---|---|---|
| 1 | 401 | Master clock | Crystal oscillator → LS368 |
| 2 | 109 | Pixel clock | 081 @ F5 pin 9 |
| 3 | 403 | /H256 | 082 @ D10 pin 10 |
| 4 | 404 | /VBlank | 082 @ D10 pin 15 |
| 5 | 405 | /VSync | 082 @ D10 pin 18 |
| 6 | 406 | Aux Enable | AND chain @ E8, one input from 083 @ B5 |
| 7 | 407 | Stars Enable | LS259 @ C3 Q4 (CPU write to 0x8204) |
| 8 | HFF | Horizontal flip | LS259 @ C3 Q6 — **role unresolved** |
| 9 | — | not connected | — |
| 10 | — | Blink clock | NE555 @ D3 pin 3, ~1.2 Hz |
| 11, 12 | — | GND | Both grounded |
| 13–18 | — | R/G/B out | 150 Ω LSB, 100 Ω MSB, into a 470 Ω node |
| 19 | 419 | Reset Enable | → RESET chain @ E1 |
| 20 | 420 | Watchdog kick | LS138 @ D5 Y2, decoding 0x8120 |
| 21 | 421 | V2 | 085 @ D9 pin 17 |
| 22 | 422 | V1 | 085 @ D9 pin 18 |
| 23 | 423 | H8Q | LS86 @ F11 — arrives inverted **and pre-flipped** |
| 24 | — | VCC | +5 |

---

## What changed functionally

**The starfield generator.** `MC_STARS` models the *Moon Cresta* circuit, a different
board. As wired it also had its horizontal gate tied off (`I_256HnX(1'b1)`), clocked its
LFSR once per pixel instead of twice, and read colour from different shift-register taps.
`k084` clocks twice per pixel, windows the RNG to the 256 counts where the horizontal
counter's bit 8 is set, clears on VBlank, and takes colour from the taps MAME's Galaxian
model uses.

**Video mixing is now additive.** On the real board each star output pair drives 100 Ω and
150 Ω into a node with 470 Ω to ground, and that node is hard-wired onto the palette ladder
with no gate between — star and palette current simply sum. The old code *replaced* the
palette colour, which also forced the background to black wherever stars were enabled.
Output now sums and saturates.

**Star brightness is corrected.** The old expansion produced roughly {0, 8, 20, 28} of 31.
The resistor network gives {0, 194, 214, 255} of 255, or {0, 24, 26, 31} at five bits — all
three lit levels sit near full brightness, where before the dimmest was at 26%.

**Stars are gated on framebuffer bit 1, not on colour 0.** The bootleg board that replaced
the 084 lets a star through when bit 1 of the 4-bit pixel is clear — eight of the sixteen
palette indices, not just the background. Pin 6 is driven from `~pixel_index[1]`.

**MAME's quarter-line suppression is not modelled.** MAME inherits
`((x & 0xc0) ^ flipxor) != 0xc0` from `galaxian.cpp`. The 084 has no H64 or H128 pin and
cannot see those counter bits. Available as `SUPPRESS_C0` for A/B comparison.

**The watchdog is modelled but not connected.** Pin 20 decodes a read of 0x8120 and pin 19
would drive reset. `wd_reset` is deliberately left unconnected: if anything else in the core
is mistimed, a live watchdog turns that into a boot loop instead of a visible glitch.

---

## Verification

The reconstructed register was traced step by step in Python and compared against MAME's
precomputed tables across the full 131,071-sample period, for both tap variants. **They
agree on every sample.** Re-run with `python tools/verify_k084.py`.

The derived 512 LFSR steps per visible line matches MAME's `star_offs = y * 512` exactly,
and 114,688 steps per frame does not wrap the period — so the pattern is static frame to
frame, which is why Tutankham's field never scrolls.

Static audit of the tree: all 118 file references across 20 `.qip` files resolve; every
instantiated module has a definition in a file that is in the build; block and bracket
balance is clean in every file touched.

**Not verified:** none of this has been through a compiler. There is no Quartus or Verilog
simulator on the machine where it was written. The algorithm is proven; the SystemVerilog
has never been read by a tool that can reject it.

---

## Known issues and open questions

**A starless band at one screen edge.** Driving pin 3 from `h_cnt[8]` as the schematic does
puts the star window at h_cnt 256–511, while this core's `hblk` puts the visible window at
269–511 plus 128–140. Both are 256 counts, so the step rate is right, but they are 13 counts
out of phase. On the real board the palette buffer at A2 is enabled over the same `h_cnt[8]`
window as the stars, so the two cannot disagree there — the offset is in this core's `hblk`,
not in the 084. Left alone because correcting it shifts the whole picture.

**Whether pin 4 clears the register for all of VBlank or pulses once as it begins.** Both
give identical density and colour distribution; only star positions move. Exposed as the
`VB_LEVEL_CLEAR` parameter rather than guessed at.

**What pin 8 does.** With H8Q pre-flipped by the LS86 at F11 and no H64/H128 to suppress,
the flip input has no remaining function the pinout explains — yet it is definitely wired to
LS259 C3 Q6.

**The LFSR internals are inherited, not proven.** The 17-bit length, the bit-12/bit-0 XNOR
feedback, the star test and the colour taps all come from MAME's Galaxian model. The
schematic shows what enters and leaves the package; it cannot show what is inside, and no
die shot exists. MAME's own source notes that neither of its starfields matches the Stern
cabinet footage — and this is exactly the part the schematic could not confirm.

---

## Build notes

Build with **Quartus 17.0.x Lite**. `sys/sys.qip` selects its PLL by Quartus major version
and only `pll_q13.qip` and `pll_q17.qip` exist, so any release from 18 onward fails at the
PLL. This is normal for MiSTer cores and is not related to these changes.

From the project root: `quartus_sh --flow compile Arcade-Tutankham`

Two harmless warnings are expected from `k084.sv`: `hff` and `hpos_hi` are only read when
`SUPPRESS_C0` is set, so at its default of 0 Quartus reports them unconnected and optimises
them away. That is the pin 8 finding showing up in the synthesis log.

---

## Sources

- 084 pinout recorded in MAME's `tutankhm.cpp`, originating in Rob Jarrett's research
- Star circuit in MAME's `tutankhm_v.cpp` and `galaxian.cpp`
- Konami bootleg daughter-board schematics contributed by Guru
- **Sheet 34D-0126-S**, C.R.T. board, page 18 of Stern Electronics' Tutankham service
  manual — the part appears as "084 / F3"

Note that the C.R.T. board crystal carries no frequency marking on the drawing. The
18.432 MHz and 6.144 MHz figures come from MAME, not from Stern's documentation.
