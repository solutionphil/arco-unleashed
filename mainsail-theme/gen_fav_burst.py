import math, random

CX, CY = 32, 32

def burst(ro, ri, n, jit, seed):
    random.seed(seed)
    pts = []
    for i in range(2 * n):
        ang = math.pi * i / n - math.pi / 2
        r = ro if i % 2 == 0 else ri
        f = 1 + random.uniform(-jit, jit)
        pts.append(f"{CX + r*f*math.cos(ang):.1f},{CY + r*f*math.sin(ang):.1f}")
    return " ".join(pts)

b1 = burst(31, 22, 15, 0.12, 5)
b2 = burst(27, 18, 15, 0.12, 5)
b3 = burst(21, 14, 11, 0.10, 2)

def mark(letter, fname):
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect x="1" y="1" width="62" height="62" rx="14" fill="#0e2247"/>
  <polygon points="{b1}" fill="#eaf2ff"/>
  <polygon points="{b2}" fill="#2e74f2"/>
  <polygon points="{b3}" fill="#5b97ff" opacity="0.7"/>
  <g font-family="'Arial Black','Arial',sans-serif" font-weight="900" font-style="italic" font-size="{34 if len(letter)==1 else 24}">
    <text x="32" y="45" text-anchor="middle" fill="none" stroke="#08152e" stroke-width="6" stroke-linejoin="round">{letter}</text>
    <text x="32" y="45" text-anchor="middle" fill="#ffffff">{letter}</text>
  </g>
</svg>'''
    open(fname, "w").write(svg)

mark("A", "favicon-alt-burst.svg")
mark("U", "favicon-source.svg")
print("ok")
