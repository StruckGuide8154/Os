#!/usr/bin/env python3
# Generate the Grit boot animation: particle-form "N" + wordmark.
# Output: build/BOOTANIM.NBA
#
# File format (little-endian):
#   0  : 'NBA1'  magic (4 bytes)
#   4  : uint32  width
#   8  : uint32  height
#  12  : uint32  frame_count
#  16  : uint32  fps
#  20  : BGRA frame data (width*height*4 * frame_count bytes)
#
# The background is a radial vignette that fades to PURE black (0,0,0) well
# before the frame edge, so the centered blit has no visible box seam against
# the black boot screen.

import math, os, struct, random, sys

W, H = 320, 180
FPS = 30
FRAMES = 36                # 1.2 seconds
DUR = FRAMES / FPS
CX, CY = W // 2, H // 2 - 6
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
OUT = os.path.join(ROOT, 'build', 'BOOTANIM.NBA')

# Hand-drawn 'N' bitmap (16 cols x 20 rows) - used to sample particle targets.
N_GLYPH = [
    "1100000000000011",
    "1100000000000011",
    "1110000000000011",
    "1110000000000011",
    "1111000000000011",
    "1111100000000011",
    "1101100000000011",
    "1101110000000011",
    "1100110000000011",
    "1100111000000011",
    "1100011000000011",
    "1100011100000011",
    "1100001100000011",
    "1100001110000011",
    "1100000110000011",
    "1100000111000011",
    "1100000011000011",
    "1100000011100011",
    "1100000001100011",
    "1100000001110011",
]

# 5x7 ASCII font for the wordmark "GRIT"
FONT = {
    'N': ["10001","11001","10101","10011","10001","10001","10001"],
    'E': ["11111","10000","10000","11110","10000","10000","11111"],
    'X': ["10001","10001","01010","00100","01010","10001","10001"],
    'U': ["10001","10001","10001","10001","10001","10001","01110"],
    'S': ["01111","10000","10000","01110","00001","00001","11110"],
    'O': ["01110","10001","10001","10001","10001","10001","01110"],
}

GLYPH_PX = 7               # pixels per N_GLYPH cell

def sample_particles():
    pts = []
    glyph_w = len(N_GLYPH[0])
    glyph_h = len(N_GLYPH)
    ox = CX - (glyph_w * GLYPH_PX) // 2
    oy = CY - (glyph_h * GLYPH_PX) // 2
    for ry, row in enumerate(N_GLYPH):
        for rx, ch in enumerate(row):
            if ch != '1':
                continue
            x = ox + rx * GLYPH_PX + GLYPH_PX // 2
            y = oy + ry * GLYPH_PX + GLYPH_PX // 2
            pts.append((x, y))
    return pts

def make_particles():
    rng = random.Random(0xBEEF)
    targets = sample_particles()
    parts = []
    for (tx, ty) in targets:
        ang = rng.random() * math.tau
        dist = 250 + rng.random() * 150
        sx = CX + math.cos(ang) * dist
        sy = CY + math.sin(ang) * dist
        delay = rng.random() * 0.40
        hue = 0.55 + rng.random() * 0.08          # blue-cyan range
        parts.append((sx, sy, tx, ty, delay, hue))
    return parts

def hsv_to_bgr(h, s, v):
    i = int(h * 6) % 6
    f = h * 6 - int(h * 6)
    p = v * (1 - s)
    q = v * (1 - f * s)
    t = v * (1 - (1 - f) * s)
    r, g, b = [(v,t,p),(q,v,p),(p,v,t),(p,q,v),(t,p,v),(v,p,q)][i]
    return int(b * 255), int(g * 255), int(r * 255)

# --- Static background: radial vignette fading to pure black ---------------
# Built once; copied into every frame.
def build_background():
    bg = bytearray(W * H * 4)
    rmax = min(W, H) * 0.48        # fully black beyond this radius
    # Peak (centre) navy tint, BGR.
    pb, pg, pr = 26, 16, 9
    for y in range(H):
        for x in range(W):
            dx = x - CX
            dy = y - CY
            d = math.sqrt(dx * dx + dy * dy)
            t = d / rmax
            if t >= 1.0:
                inten = 0.0
            else:
                inten = (1.0 - t) ** 1.7
            o = (y * W + x) * 4
            bg[o]   = int(pb * inten)
            bg[o+1] = int(pg * inten)
            bg[o+2] = int(pr * inten)
            bg[o+3] = 0xFF
    return bg

BG = build_background()

def plot(buf, x, y, b, g, r, a=255):
    if x < 0 or x >= W or y < 0 or y >= H:
        return
    o = (y * W + x) * 4
    if a >= 255:
        buf[o] = b; buf[o+1] = g; buf[o+2] = r
    else:
        inv = 255 - a
        buf[o]   = (buf[o]   * inv + b * a) >> 8
        buf[o+1] = (buf[o+1] * inv + g * a) >> 8
        buf[o+2] = (buf[o+2] * inv + r * a) >> 8

def plot_blk(buf, x, y, b, g, r, a, sz):
    for dy in range(sz):
        for dx in range(sz):
            plot(buf, x + dx, y + dy, b, g, r, a)

def draw_glow(buf, cx, cy, radius, b, g, r, strength):
    r2 = radius * radius
    for dy in range(-radius, radius + 1):
        yy = cy + dy
        if yy < 0 or yy >= H: continue
        for dx in range(-radius, radius + 1):
            xx = cx + dx
            if xx < 0 or xx >= W: continue
            d2 = dx * dx + dy * dy
            if d2 > r2: continue
            f = (1 - d2 / r2) ** 2
            a = int(strength * f * 255)
            if a <= 0: continue
            plot(buf, xx, yy, b, g, r, min(255, a))

def draw_text(buf, text, x, y, b, g, r, a=255, scale=1):
    px = x
    for ch in text:
        glyph = FONT.get(ch.upper())
        if not glyph:
            px += 4 * scale
            continue
        for row_i, row in enumerate(glyph):
            for col_i, c in enumerate(row):
                if c == '1':
                    for sy in range(scale):
                        for sx in range(scale):
                            plot(buf, px + col_i * scale + sx,
                                       y + row_i * scale + sy, b, g, r, a)
        px += (len(glyph[0]) + 1) * scale

def ease_out_cubic(u):
    return 1 - (1 - u) ** 3

def render_frame(idx, particles):
    t = idx / FPS
    buf = bytearray(BG)            # start from the vignette background

    # Subtle pulsing halo
    pulse = (math.sin(t * 4.5) + 1) * 0.5
    halo_strength = 0.10 + 0.10 * pulse
    draw_glow(buf, CX, CY, 84, 255, 170, 90, halo_strength)

    # Particles
    settled = t >= 1.1
    for (sx, sy, tx, ty, delay, hue) in particles:
        u_raw = (t - delay) / 1.0
        u = max(0.0, min(1.0, u_raw))
        e = ease_out_cubic(u)
        px = sx * (1 - e) + tx * e
        py = sy * (1 - e) + ty * e
        # Color: start bluish, settle to a bright cyan.
        v = 0.72 + 0.28 * e
        bgr = hsv_to_bgr(hue, 0.70 - 0.45 * e, v)
        b, g, r = bgr
        a = int(90 + 165 * e)
        plot_blk(buf, int(px), int(py), b, g, r, a, 3)
        # Tail when still travelling
        if 0.05 < u < 1.0:
            tail_n = 3
            for k in range(1, tail_n + 1):
                kk = max(0.0, u - 0.04 * k)
                ek = ease_out_cubic(kk)
                tx2 = sx * (1 - ek) + tx * ek
                ty2 = sy * (1 - ek) + ty * ek
                ta = int(a * (1 - k / (tail_n + 1)) * 0.35)
                if ta > 4:
                    plot_blk(buf, int(tx2), int(ty2), b, g, r, ta, 2)

    # Settle flash + glow around the N
    if settled:
        s = min(1.0, (t - 1.1) / 0.4)
        draw_glow(buf, CX, CY, 64, 255, 200, 120, 0.18 * s)
        draw_glow(buf, CX, CY, 37, 255, 240, 180, 0.30 * s)

    # Wordmark "GRIT"
    wa = max(0.0, min(1.0, (t - 0.95) / 0.55))
    if wa > 0:
        text = "GRIT"
        scale = 3
        text_w = (5 + 1) * scale * len(text) - scale
        tx = CX - text_w // 2
        ty = CY + 58
        a = int(wa * 255)
        draw_text(buf, text, tx, ty, 0xF0, 0xE6, 0xD8, a, scale=scale)

    return buf

def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    particles = make_particles()
    print(f"[boot-anim] {W}x{H} {FRAMES}f @ {FPS}fps  particles={len(particles)}")
    with open(OUT, 'wb') as f:
        f.write(b'NBA1')
        f.write(struct.pack('<IIII', W, H, FRAMES, FPS))
        poster = render_frame(FRAMES - 1, particles)
        for i in range(FRAMES):
            f.write(poster if i == 0 else render_frame(i, particles))
            if i % 5 == 0:
                sys.stdout.write('.'); sys.stdout.flush()
    sz = os.path.getsize(OUT)
    print(f"\n[boot-anim] wrote {OUT}  ({sz/1024:.1f} KB)")

if __name__ == '__main__':
    main()
