#!/usr/bin/env python3
"""Turn a frame saved by `xcap_test grab` (4 KB header + v210 pixels) into a PNG for viewing.

usage: frame_to_png.py grab.frm out.png [scale]
HDR (PQ, BT.2020) frames are tone mapped roughly to SDR so they can be looked at; SDR frames are taken as BT.709.
Needs numpy and pillow.
"""
import struct
import sys

import numpy as np
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
scale = int(sys.argv[3]) if len(sys.argv) > 3 else 2
raw = open(src, 'rb').read()
magic, version, seq, flags, ts, geom, stride, pixfmt, data_bytes = struct.unpack_from('<4IQ4I', raw, 0)
w, h = geom & 0xFFFF, geom >> 16
meta = struct.unpack_from('<16I', raw, 48)
hdr = meta[0] & 1 and (meta[0] >> 4) & 15 == 2
print(f'{w}x{h} stride {stride} pixfmt {pixfmt} seq {seq} meta flags {meta[0]:02x} -> {"PQ BT.2020" if hdr else "SDR"}')
px = np.frombuffer(raw, dtype='<u4', offset=4096, count=stride * h // 4).reshape(h, stride // 4)
if pixfmt == 1 or stride == w * 4:     # BGRX8
    rgb = px[:, :w].view(np.uint8).reshape(h, w, 4)[:, :, 2::-1].astype(np.float32) / 255
else:                                  # v210: 4 words = 6 pixels
    g = px[:, :(w // 6) * 4].reshape(h, w // 6, 4)
    a, b, c = (g & 0x3FF), (g >> 10) & 0x3FF, (g >> 20) & 0x3FF
    Y = np.stack([b[..., 0], a[..., 1], c[..., 1], b[..., 2], a[..., 3], c[..., 3]], -1).reshape(h, w)
    Cb = np.stack([a[..., 0], b[..., 1], c[..., 2]], -1).reshape(h, w // 2)
    Cr = np.stack([c[..., 0], a[..., 2], b[..., 3]], -1).reshape(h, w // 2)
    Cb, Cr = np.repeat(Cb, 2, 1), np.repeat(Cr, 2, 1)
    y = (Y.astype(np.float32) - 64) / 876
    u = (Cb.astype(np.float32) - 512) / 896
    v = (Cr.astype(np.float32) - 512) / 896
    if hdr:   # BT.2020 non-constant luminance
        r, gg, bb = y + 1.4746 * v, y - 0.16455 * u - 0.57135 * v, y + 1.8814 * u
    else:
        r, gg, bb = y + 1.5748 * v, y - 0.1873 * u - 0.4681 * v, y + 1.8556 * u
    rgb = np.clip(np.stack([r, gg, bb], -1), 0, 1)
if hdr:
    m1, m2, c1, c2, c3 = 0.1593017578125, 78.84375, 0.8359375, 18.8515625, 18.6875
    e = rgb ** (1 / m2)
    lin = (np.maximum(e - c1, 0) / (c2 - c3 * e)) ** (1 / m1) * 10000 / 203   # 1.0 = HDR reference white
    m = np.array([[1.6605, -0.5876, -0.0728], [-0.1246, 1.1329, -0.0083], [-0.0182, -0.1006, 1.1187]], np.float32)
    lin = np.clip(lin @ m.T, 0, None)
    lin = lin / (1 + lin / 4)              # soft knee, keeps highlights visible
    rgb = np.where(lin <= 0.0031308, 12.92 * lin, 1.055 * np.power(lin, 1 / 2.4) - 0.055)
img = Image.fromarray((np.clip(rgb, 0, 1) * 255 + 0.5).astype(np.uint8))
if scale > 1:
    img = img.resize((w // scale, h // scale), Image.LANCZOS)
img.save(dst)
print('saved', dst)
