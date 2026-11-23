#!/usr/bin/env python3
"""classify TX link snapshots: per file, chars per channel: control tokens (C00..C11), TERC4 (data island), video guard, other (video)"""
import sys
CTL={0x354:'C00',0x0AB:'C01',0x154:'C10',0x2AB:'C11'}
TERC4={0x29C,0x263,0x2E4,0x2E2,0x171,0x11E,0x18E,0x13C,0x2CC,0x139,0x19C,0x2C6,0x28E,0x271,0x163,0x2C3}
def load(p):
    snaps=[];cur=[]
    for l in open(p):
        l=l.strip()
        if not l: continue
        if l.startswith('#'):
            if cur: snaps.append(cur)
            cur=[]; continue
        cur.append(int(l,16))
    if cur: snaps.append(cur)
    return snaps
def chars(words,ch):
    o=[]
    for w in words:
        x=(w>>(20*ch))&0xFFFFF
        o.append(x&0x3FF); o.append(x>>10)
    return o
def summ(words):
    out=[]
    for ch in range(3):
        c=chars(words,ch); d={}
        for x in c:
            k=CTL.get(x) or ('T4' if x in TERC4 else 'vid')
            d[k]=d.get(k,0)+1
        out.append(' '.join(f'{k}:{v}' for k,v in sorted(d.items())))
    return f'{len(set(words)):3d} distinct | ch0 {out[0]} | ch1 {out[1]} | ch2 {out[2]}'
if __name__=='__main__':
  for p in sys.argv[1:]:
    for i,s in enumerate(load(p)):
        print(f'{p.split("/")[-1]}#{i}: {summ(s)}')
