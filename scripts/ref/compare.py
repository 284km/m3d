#!/usr/bin/env python3
"""Compare m3d's frame with three.js's, and say which part of the difference is which.

Three numbers per model:

  IoU over the silhouette. Same geometry, same transforms, same camera, so which pixels
  are covered has one right answer. This is what catches a wrong matrix, a dropped node,
  a flipped winding or a mis-read accessor. It is not 1.0 even when both are right,
  because the two rasterizers resolve a boundary pixel differently, so it is pinned per
  model AND floored absolutely -- a pin alone would have let a table of IoU 0.000 read as
  a pass, which is what it did on the first run of this gate.

  MAE against STOCK three.js, over the pixels both covered. three.js diverges from
  glTF's normative appendix in ways m3d deliberately does not follow, so this number is
  recorded rather than thresholded.

  MAE against three.js PATCHED to glTF's appendix (?gltfbrdf=1). This is where the
  interesting claim lives: on a model that uses no feature m3d is missing, it is 0.0 --
  the two renderers are byte-identical -- and a 0.0 pin is held to 0.0 exactly.

An unpinned model is a FAILURE, not a pass. A gate that silently accepts whatever it is
shown for a model nobody has looked at is not checking that model.

A pin may carry trailing text, and when it does that text is a REASON: the feature this
renderer has not implemented, which is why that model's silhouette disagrees. It is the
only thing that waives the absolute IoU floor, so "not implemented yet" has to be written
down as a sentence rather than absorbed into a number.
"""
import os, re, sys, warnings
warnings.filterwarnings("ignore")
from PIL import Image

# The clear colour both renderers are given -- a saturated magenta, chosen so that
# "covered" is decidable. Against a dark background a dark surface reads as no surface,
# and the silhouette measure then answers a colour question instead of a geometry one:
# Suzanne sat at 0.92 with nothing wrong with its geometry, and adding a texture slot
# moved that number. Magenta is not proof -- a magenta emissive surface would still fool
# it -- and the exact answer is two renders on two backgrounds, which is not paid for.
BG = (255, 0, 255)
IOU_FLOOR = 0.95                  # below this, no pin makes it acceptable
IOU_SLACK = 0.005                 # a pin may not fall by more than this
MAE_SLACK_STOCK = 1.0             # ... nor may the stock colour pin rise by more than this
# Tighter on the patched column, because the numbers there are small: Box sits at 0.07,
# which is one least-significant bit on a tenth of its pixels, and a whole extra bit
# everywhere would be about 0.33. A slack of 1.0 would have waved that through.
MAE_SLACK_PATCHED = 0.5
PINS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pinned.txt")


SENTINEL = (0, 255, 13)   # what scripts/ref/page.html paints once the render returns


def load(p):
    im = Image.open(p).convert("RGB")
    return im.size, list(im.getdata())


def load_reference(p, size):
    """A reference frame, with its finished-render strip checked and then cropped off.

    The strip is the instrument's own proof of life. A screenshot taken while the page
    was still loading is a perfectly valid PNG of the right dimensions and the right
    background colour, and every number computed from it is an answer to nothing.
    """
    im = Image.open(p).convert("RGB")
    w, h = im.size
    if (w, h) != (size, size + 4):
        return None, f"{os.path.basename(p)} is {w}x{h}, not {size}x{size + 4}"
    strip = [im.getpixel((x, size + 2)) for x in range(0, w, max(1, w // 8))]
    if any(px != SENTINEL for px in strip):
        return None, (f"{os.path.basename(p)} has no finished-render strip "
                      f"(saw {strip[0]}, wanted {SENTINEL}) — the browser was screenshotted "
                      f"before three.js had drawn anything")
    return list(im.crop((0, 0, size, size)).getdata()), None


def covered(p):
    return abs(p[0] - BG[0]) + abs(p[1] - BG[1]) + abs(p[2] - BG[2]) > 6


def mae(a, b, mask):
    """Mean absolute channel difference, and what share of the pixels differ at all.

    The share is the sharp one. A mean of 0.00 can be a hundredth of a bit spread over a
    tenth of the image, and printed to two places it looks like exactness -- which is how
    a pin of "byte-identical" first passed on two models that were not. "0.0% of pixels
    differ" cannot round its way out of being wrong.
    """
    n = sum(1 for m in mask if m)
    if n == 0:
        return None, None
    tot = 0
    ndiff = 0
    for p, q, m in zip(a, b, mask):
        if not m:
            continue
        d = abs(p[0] - q[0]) + abs(p[1] - q[1]) + abs(p[2] - q[2])
        tot += d
        if d:
            ndiff += 1
    return tot / (3 * n), 100.0 * ndiff / n


def read_pins():
    pins = {}
    if os.path.exists(PINS):
        for line in open(PINS):
            line = line.split("#")[0].strip()
            if not line:
                continue
            # A TAB SEPARATES THE NAME FROM THE NUMBERS, and nothing else does.
            #
            # `line.split()` was the obvious reading, and it silently dropped
            # `Box With Spaces` -- the model Khronos ships to break exactly that
            # assumption -- leaving it unpinnable and therefore permanently failing, in
            # a way that read as a missing pin. "Everything up to two or more spaces"
            # was the next attempt and it dropped `TextureLinearInterpolationTest`,
            # which is thirty characters and fills the column, leaving one space after
            # it. Both were guesses about layout. A tab is not a guess: these names come
            # from directory names and cannot contain one.
            if "\t" not in line:
                continue
            name, _, rest = line.partition("\t")
            t = rest.split()
            if len(t) < 5:
                continue
            try:
                nums = tuple(float(x) for x in t[:5])
            except ValueError:
                continue
            # A row may carry trailing text, and when it does that text is a REASON:
            # the feature this renderer has not implemented yet. It is the only thing
            # that lets a row sit below the absolute IoU floor -- see below.
            pins[name.strip()] = (nums, " ".join(t[5:]))
    return pins


def main():
    name, mine_p, stock_p, patched_p, nomip_p = sys.argv[1:6]
    (w, h), a = load(mine_p)
    if w != h:
        print(f"{name:<30} FAIL — m3d wrote {w}x{h}, and this gate renders squares")
        return 1
    b, err = load_reference(stock_p, w)
    if err is None:
        c, err = load_reference(patched_p, w)
    if err is None and nomip_p != patched_p:
        e, err = load_reference(nomip_p, w)
    else:
        e = c
    if err is not None:
        print(f"{name:<30} FAIL — {err}")
        return 1

    ca = [covered(p) for p in a]
    cb = [covered(p) for p in b]
    both = [x and y for x, y in zip(ca, cb)]
    union = sum(1 for x, y in zip(ca, cb) if x or y)
    inter = sum(1 for m in both if m)
    if union < 100:
        print(f"{name:<30} FAIL — only {union} pixels covered by either, so nothing was compared")
        return 1
    iou = inter / union
    m_stock, _ = mae(a, b, both)
    m_patch, _ = mae(a, c, [x and covered(q) for x, q in zip(ca, c)])
    # THE COLUMN THAT MEASURES THIS RENDERER. The two above measure three.js's
    # departures from glTF and this renderer's missing mipmaps; with both taken out
    # of the way, what is left is the shading m3d actually implements. So the
    # differing-pixel share is taken from THIS comparison and not from the middle
    # one -- it is the sharp number, and it should be sharp about the right thing.
    m_nomip, pct = mae(a, e, [x and covered(q) for x, q in zip(ca, e)])

    problems = []
    pins = read_pins()
    if name not in pins:
        problems.append("unpinned — put a line in scripts/ref/pinned.txt")
        if iou < IOU_FLOOR:
            problems.append(f"IoU {iou:.3f} is below the absolute floor {IOU_FLOOR}")
    else:
        (pi, ps, pp, pn, pd), reason = pins[name]
        # THE FLOOR CAN ONLY BE WAIVED BY NAMING WHAT IT IS WAITING ON. Some models
        # disagree about their silhouette because this renderer does not implement a
        # feature they use -- skinning, morph targets -- and pinning those rows at
        # whatever they happen to measure would quietly turn "not implemented" into
        # "as expected". A row below the floor must say which feature, in the pin file,
        # and when that feature lands the sentence becomes false in a place someone
        # reads.
        if iou < IOU_FLOOR and not reason:
            problems.append(f"IoU {iou:.3f} is below the absolute floor {IOU_FLOOR} "
                            f"and the pin gives no reason")
        if iou < pi - IOU_SLACK:
            problems.append(f"IoU fell from its pin {pi:.3f}")
        if m_stock > ps + MAE_SLACK_STOCK:
            problems.append(f"stock MAE rose from its pin {ps:.1f}")
        # A pin of 0 differing pixels is a claim of byte-identical output. It gets no
        # slack: the whole value of such a pin is that ONE changed pixel breaks it.
        if pd == 0.0:
            if m_nomip != 0.0 or pct != 0.0:
                problems.append(f"the two renderers were byte-identical here and now differ on {pct:.2f}% of pixels")
        else:
            if m_patch > pp + MAE_SLACK_PATCHED:
                problems.append(f"glTF-BRDF MAE rose from its pin {pp:.2f}")
            if m_nomip > pn + MAE_SLACK_PATCHED:
                problems.append(f"the comparable MAE rose from its pin {pn:.2f}")
            if pct > pd + 2.0:
                problems.append(f"the share of differing pixels rose from its pin {pd:.1f}%")

    note = "FAIL — " + "; ".join(problems) if problems else ""
    print(f"{name:<30} {iou:<7.3f} {m_stock:<8.1f} {m_patch:<10.3f} "
          f"{m_nomip:<9.3f} {pct:<7.2f} {note}")
    return 1 if problems else 0


sys.exit(main())
