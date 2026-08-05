import math, random

CX, CY = 126, 36

def burst(rx_o, ry_o, rx_i, ry_i, n, jit, seed):
    random.seed(seed)
    pts = []
    for i in range(2 * n):
        ang = math.pi * i / n - math.pi / 2
        rx, ry = (rx_o, ry_o) if i % 2 == 0 else (rx_i, ry_i)
        f = 1.0 + random.uniform(-jit, jit)
        x = CX + rx * f * math.cos(ang)
        y = CY + ry * f * math.sin(ang)
        pts.append(f"{x:.1f},{y:.1f}")
    return " ".join(pts)

back  = burst(126, 36, 96, 22, 17, 0.12, 7)   # white outer shards
mid   = burst(116, 31, 88, 19, 17, 0.12, 7)   # electric-blue body
inner = burst( 96, 25, 74, 16, 13, 0.10, 3)   # lighter-blue core

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 252 72">
  <polygon points="{back}"  fill="#eaf2ff"/>
  <polygon points="{mid}"   fill="#2e74f2"/>
  <polygon points="{inner}" fill="#5b97ff" opacity="0.65"/>
  <g font-family="'Arial Black','Archivo Black','Arial',sans-serif" font-weight="900" font-style="italic" font-size="28" letter-spacing="-0.5">
    <text x="15" y="47" fill="#071529" opacity="0.55">UNLEASHED!</text>
    <text x="13" y="45" fill="none" stroke="#071529" stroke-width="6" stroke-linejoin="round">UNLEASHED!</text>
    <text x="13" y="45" fill="#ffffff">UNLEASHED!</text>
  </g>
</svg>'''

open("sidebar-logo.svg", "w").write(svg)
print("sidebar-logo.svg written")
