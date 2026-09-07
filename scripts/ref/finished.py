#!/usr/bin/env python3
"""Exit 0 if a reference screenshot carries page.html's finished-render strip.

Headless Chrome sometimes screenshots before the compositor has drawn. What it writes
then is a valid PNG of the right size in the right background colour, so nothing
downstream can tell it apart from a render -- it just answers a different question. The
page paints a four-pixel strip below the canvas after three.js returns, and this is the
reader for it.
"""
import sys
from PIL import Image

im = Image.open(sys.argv[1]).convert("RGB")
n = int(sys.argv[2])
ok = im.size == (n, n + 4) and im.getpixel((n // 2, n + 2)) == (0, 255, 13)
sys.exit(0 if ok else 1)
