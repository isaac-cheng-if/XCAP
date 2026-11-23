#!/usr/bin/env python3
"""HDMI 2.0 scrambled link snapshots: is the data "constant pixels XOR a 16-bit LFSR"?  scr.py file.multi
For flat picture areas (colour bars) every bit of the TMDS-decoded bytes is an LFSR sequence (plus a constant), so its linear
complexity (Berlekamp-Massey) over a window is <= 17 instead of about half the window length as for random data."""
import sys
sys.path.insert(0, __file__.rsplit('/',1)[0])
from an import load, chars
from dec import tmds8
def bm(s):
    n=len(s); c=[0]*n; b=[0]*n; c[0]=b[0]=1; L=0; m=-1
    for i in range(n):
        d=s[i]
        for j in range(1,L+1): d^=c[j]&s[i-j]
        if d:
            t=c[:]
            for j in range(n-i+m): c[i-m+j]^=b[j]
            if L<=i//2: L=i+1-L; m=i; b=t
    return L
W=96
def main():
    sn=load(sys.argv[1]); tot=0; low=0; per=[]
    for s in sn:
        k=0; w=0
        for ch in range(3):
            d=[tmds8(x) for x in chars(s,ch)]
            for o in range(0,1024-W+1,W):
                for bit in (0,7):
                    L=bm([(x>>bit)&1 for x in d[o:o+W]]); w+=1; k+= L<=17
        per.append(f'{k}/{w}'); tot+=w; low+=k
    print(f'{len(sn)} snapshots, windows of {W} characters with linear complexity <= 17 (scrambled flat picture): {low} of {tot}')
    print('per snapshot:', ' '.join(per))
if __name__=='__main__': main()
