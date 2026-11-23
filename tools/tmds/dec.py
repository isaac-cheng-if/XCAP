#!/usr/bin/env python3
"""decode TX link snapshots (unscrambled TMDS): run-length list of what each snapshot holds.  dec.py file.multi [max snapshots]"""
import sys
sys.path.insert(0, __file__.rsplit('/',1)[0])
from an import load, chars, CTL, TERC4   # noqa
def tmds8(c):
    d = c & 0xFF
    if c & 0x200: d ^= 0xFF
    q = d
    o = q & 1
    for i in range(1, 8):
        b = ((q >> i) & 1) ^ ((q >> (i-1)) & 1)
        if not (c & 0x100): b ^= 1
        o |= b << i
    return o
T4 = {v:i for i,v in enumerate([0x29C,0x263,0x2E4,0x2E2,0x171,0x11E,0x18E,0x13C,0x2CC,0x139,0x19C,0x2C6,0x28E,0x271,0x163,0x2C3])}
def main():
    snaps = load(sys.argv[1]); mx = int(sys.argv[2]) if len(sys.argv) > 2 else len(snaps)
    for n, s in enumerate(snaps[:mx]):
        c = [chars(s, ch) for ch in range(3)]
        items = []
        for i in range(len(c[0])):
            t = tuple(c[ch][i] for ch in range(3))
            if all(x in CTL for x in t): k = 'ctl ' + '/'.join(CTL[x] for x in t)      # ch0 = hsync/vsync, ch1/2 = preamble
            elif t[0] in (0x2CC,) and t[1] == 0x133 and t[2] == 0x2CC: k = 'video guard'
            elif t[1] == 0x133 and t[2] == 0x133 and t[0] in T4: k = 'island guard'
            elif all(x in T4 for x in t): k = 'island %x%x%x' % (T4[t[2]], T4[t[1]], T4[t[0]])
            else: k = 'pix %02x %02x %02x' % (tmds8(t[2]), tmds8(t[1]), tmds8(t[0]))
            if k.startswith('island ') : k = 'island data'
            if items and items[-1][0] == k: items[-1][1] += 1
            else: items.append([k, 1])
        print(f'#{n}: ' + ', '.join(f'{k} x{v}' for k, v in items))
if __name__=="__main__": main()
