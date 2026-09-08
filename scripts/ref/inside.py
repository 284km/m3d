#!/usr/bin/env python3
"""The camera inside the geometry: does the clipped picture agree with three.js?

The corpus frames every model from OUTSIDE, so nothing in it crosses the near plane and
nothing in it could notice that a triangle with a vertex behind the plane was dropped
whole. With the eye inside Box, three.js filled all 36,864 pixels and this renderer drew
ZERO. That is what this compares.

BOTH SIDES MUST FILL THE FRAME, and the check says so separately from the agreement:
two renderers that both drew nothing would agree perfectly, and a silhouette measure
would report 1.000 about it.
"""
import sys
from PIL import Image

BG = (255, 0, 255)


def cov(px):
    return abs(px[0] - BG[0]) + abs(px[1] - BG[1]) + abs(px[2] - BG[2]) > 6


mine_p, ref_p, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
mine = Image.open(mine_p).convert("RGB")
ref = Image.open(ref_p).convert("RGB")
if mine.size != (n, n):
    print(f"near-plane: FAIL - m3d wrote {mine.size[0]}x{mine.size[1]}, not {n}x{n}")
    sys.exit(1)
# The reference is a screenshot, so it is one finished-render strip taller. `shoot` has
# already refused it if the strip is missing; here it is simply cropped off.
if ref.size != (n, n + 4):
    print(f"near-plane: FAIL - the reference is {ref.size[0]}x{ref.size[1]}, not {n}x{n + 4}")
    sys.exit(1)
ref = ref.crop((0, 0, n, n))
a, b = list(mine.getdata()), list(ref.getdata())
tot = n * n
ca = sum(1 for p in a if cov(p))
cb = sum(1 for p in b if cov(p))
inter = sum(1 for x, y in zip(a, b) if cov(x) and cov(y))
union = sum(1 for x, y in zip(a, b) if cov(x) or cov(y))
iou = inter / union if union else 1.0
print(f"{'near-plane (eye inside Box)':<30} {iou:<7.3f} m3d {ca}/{tot}, three.js {cb}/{tot}")

# The reference filling the frame is the PRECONDITION: if it does not, the camera is not
# where this check thinks it is, and everything below would be measuring the wrong view.
if cb != tot:
    print(f"near-plane: FAIL - the reference covered {cb}/{tot}; the camera is not inside the box")
    sys.exit(1)
if ca != tot:
    print(f"near-plane: FAIL - m3d covered {ca}/{tot} with the eye inside the box (it was 0 before clipping)")
    sys.exit(1)
if iou < 0.999:
    print(f"near-plane: FAIL - IoU {iou:.3f} against three.js")
    sys.exit(1)
