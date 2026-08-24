"""
Cross-check the k084.sv RTL model against MAME's tutankhm_v.cpp starfield.

Two independent implementations are built here:
  * mame_table()  - a literal transcription of stars_init_scramble()
  * rtl_stream()  - a cycle-level trace of what rtl/custom/k084.sv does

If the RTL is a faithful model they must agree sample for sample.
"""
import struct
import zlib

STAR_RNG_PERIOD = (1 << 17) - 1

VISIBLE_W = 256
VISIBLE_H = 224


# ---------------------------------------------------------------- MAME side --

def mame_table():
    """Literal transcription of tutankhm_state::stars_init_scramble()."""
    stars = bytearray(STAR_RNG_PERIOD)
    shiftreg = 0
    for i in range(STAR_RNG_PERIOD):
        enabled = (shiftreg & 0x1FE01) == 0x1FE00
        color = (~shiftreg & 0x1F8) >> 3
        stars[i] = color | (enabled << 7)
        shiftreg = (shiftreg >> 1) | ((((shiftreg >> 12) ^ ~shiftreg) & 1) << 16)
    return stars


def mame_bootleg_table():
    """Literal transcription of tutankhm_state::stars_init_bootleg()."""
    stars = bytearray(STAR_RNG_PERIOD)
    shiftreg = 0
    for i in range(STAR_RNG_PERIOD):
        newbit = ((shiftreg >> 12) ^ ~shiftreg) & 1
        enabled = ((shiftreg & 0x1FE00) == 0x1FE00) and (newbit == 0)
        color = (~shiftreg & 0x1F8) >> 3
        stars[i] = color | (enabled << 7)
        shiftreg = (shiftreg >> 1) | (newbit << 16)
    return stars


# ----------------------------------------------------------------- RTL side --

def rtl_stream(n, bootleg=False):
    """Trace k084.sv: lfsr, feedback, star_hit and star_col, step by step."""
    out = bytearray(n)
    lfsr = 0
    for i in range(n):
        feedback = (lfsr >> 12) & 1 ^ (~lfsr & 1)          # lfsr[12] ^ ~lfsr[0]
        top8 = (lfsr >> 9) & 0xFF                          # lfsr[16:9]
        gap = (not feedback) if bootleg else (not (lfsr & 1))
        star_hit = (top8 == 0xFF) and gap
        star_col = (~(lfsr >> 3)) & 0x3F                   # ~lfsr[8:3]
        out[i] = star_col | (star_hit << 7)
        lfsr = ((feedback << 16) | (lfsr >> 1)) & 0x1FFFF  # {feedback, lfsr[16:1]}
    return out


# ------------------------------------------------------------------- checks --

def check(name, a, b):
    if a == b:
        print(f"  PASS  {name}")
        return True
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            print(f"  FAIL  {name}: first difference at step {i}: "
                  f"mame=0x{x:02x} rtl=0x{y:02x}")
            return False
    print(f"  FAIL  {name}: length mismatch {len(a)} vs {len(b)}")
    return False


print("Comparing RTL model against MAME reference tables")
print()

N = STAR_RNG_PERIOD
ok = True
ok &= check("scramble / genuine 084 tap (bootleg_mode=0)",
            mame_table(), rtl_stream(N, bootleg=False))
ok &= check("bootleg daughter-board tap (bootleg_mode=1)",
            mame_bootleg_table(), rtl_stream(N, bootleg=True))
print()

# ----------------------------------------------------- pixel-level behaviour --

stars = mame_table()

# k084 clocks the LFSR twice per visible pixel, gated to the 256 visible pixels
# of each visible line, and clears at VBlank -> exactly 512 steps per line,
# which is MAME's stars_draw_row(..., star_offs = y * 512).
per_line = VISIBLE_W * 2
print(f"LFSR steps per visible line: {per_line}  "
      f"(MAME uses star_offs = y*512 -> {'match' if per_line == 512 else 'MISMATCH'})")

frame_steps = per_line * VISIBLE_H
print(f"LFSR steps per frame:        {frame_steps}")
print(f"LFSR period:                 {STAR_RNG_PERIOD}")
print(f"Wraps within a frame:        {'yes' if frame_steps > STAR_RNG_PERIOD else 'no'}"
      "  (no wrap => pattern is static frame to frame)")
print()


def blink_mask(state, x, y):
    """The four NE555 blink states, from stars_draw_row()."""
    h8q = (~x >> 3) & 1
    if state == 0:
        return True
    if state == 1:
        return bool(y & 1)
    if state == 2:
        return bool((y >> 1) & 1)
    return bool(h8q)


def render(blink_state, suppress_c0, flip=False):
    """One frame of stars, as pixels. Returns list of (x, y, colour6)."""
    hits = []
    flipxor = 0xC0 if flip else 0x00
    for y in range(VISIBLE_H):
        offs = y * per_line
        for x in range(VISIBLE_W):
            h8q = (~x >> 3) & 1
            dither = ((y ^ h8q) & 1) == 1
            enab = blink_mask(blink_state, x, y)
            if suppress_c0 and ((x & 0xC0) ^ flipxor) == 0xC0:
                continue
            if not (dither and enab):
                continue
            a = stars[(offs + 2 * x) % STAR_RNG_PERIOD]
            b = stars[(offs + 2 * x + 1) % STAR_RNG_PERIOD]
            # The second sample covers 2/3 of the pixel, so it wins.
            if b & 0x80:
                hits.append((x, y, b & 0x3F))
            elif a & 0x80:
                hits.append((x, y, a & 0x3F))
    return hits


print("Star counts over the 256x224 visible area:")
total_px = VISIBLE_W * VISIBLE_H
for state in range(4):
    on = render(state, suppress_c0=False)
    off = render(state, suppress_c0=True)
    print(f"  blink state {state}: {len(on):5d} stars "
          f"({100.0 * len(on) / total_px:4.1f}% of screen)   "
          f"with MAME's x&0xc0 suppression: {len(off):5d}")
print()


# --------------------------------------------------------------- PNG output --

# MAME's galaxian_palette() star levels: 0, 194, 214, 255 out of 255.
STARMAP = [0, 194, 214, 255]


def colour_to_rgb(c6):
    """c6[5]/c6[4] = red 150/100 ohm, [3]/[2] = green, [1]/[0] = blue."""
    r = STARMAP[(((c6 >> 4) & 1) << 1) | ((c6 >> 5) & 1)]
    g = STARMAP[(((c6 >> 2) & 1) << 1) | ((c6 >> 3) & 1)]
    b = STARMAP[(((c6 >> 0) & 1) << 1) | ((c6 >> 1) & 1)]
    return r, g, b


def write_png(path, width, height, pixels):
    """Minimal PNG writer (stdlib only)."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0
        row = pixels[y]
        for px in row:
            raw += bytes(px)

    def chunk(tag, data):
        c = tag + data
        return (struct.pack(">I", len(data)) + c
                + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


import os
outdir = os.path.dirname(os.path.abspath(__file__))
for state in range(4):
    grid = [[(0, 0, 0)] * VISIBLE_W for _ in range(VISIBLE_H)]
    for x, y, c6 in render(state, suppress_c0=False):
        grid[y][x] = colour_to_rgb(c6)
    path = os.path.join(outdir, f"starfield_blink{state}.png")
    write_png(path, VISIBLE_W, VISIBLE_H, grid)
    print(f"wrote {path}")

print()
print("RESULT:", "all RTL/MAME comparisons agree" if ok else "MISMATCH - see above")
