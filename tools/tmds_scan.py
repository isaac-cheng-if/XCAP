#!/usr/bin/env python3
"""Look for TMDS control tokens in an ILA capture of HDMI link data (20 bits = 2 characters per clock and channel).

usage: tmds_scan.py capture.csv
Input: a .txt dump of xcap_linkcap (one 60-bit hex word per line) or an ILA CSV (write_hw_ila_data -csv_file). Each row's probe0 holds three channels of 20 bits,
channel 0 in the low bits. Raw receive data is not word aligned, so every bit offset is tried, plus the bit-reversed
and inverted streams, to tell an alignment problem from a bit-order or polarity problem.
"""
import csv
import sys

TOKENS = {0x354: 'C00', 0x0AB: 'C01', 0x154: 'C10', 0x2AB: 'C11'}


def rows(path):
    if path.endswith('.txt'):                 # one hex word per line (xsdb dump of xcap_linkcap)
        with open(path) as f:
            for line in f:
                if line.strip():
                    yield int(line, 16)
        return
    with open(path, newline='') as f:
        r = csv.reader(f)
        head = next(r)
        col = next(i for i, h in enumerate(head) if 'probe0' in h.lower() or 'tdata' in h.lower() or h.startswith('u_'))
        radix = next(r, None)  # second header line holds the radix
        for row in r:
            v = row[col].strip()
            yield int(v, 16) if not v.lower().startswith('0b') else int(v[2:], 2)


def bits_of(words, ch, lsb_first=True):
    out = []
    for w in words:
        x = (w >> (20 * ch)) & 0xFFFFF
        seq = [(x >> i) & 1 for i in range(20)]
        out.extend(seq if lsb_first else seq[::-1])
    return out


def scan(bits, invert=False):
    best = (0, 0)
    for off in range(10):
        n = 0
        for i in range(off, len(bits) - 10, 10):
            c = 0
            for k in range(10):
                c |= (bits[i + k] ^ invert) << k
            n += c in TOKENS
        best = max(best, (n, off))
    return best


def main():
    words = list(rows(sys.argv[1]))
    print(f'{len(words)} samples, first words: ' + ' '.join(f'{w:015x}' for w in words[:4]))
    for ch in range(3):
        for lsb in (True, False):
            for inv in (False, True):
                n, off = scan(bits_of(words, ch, lsb), inv)
                print(f'ch{ch} {"lsb" if lsb else "msb"}-first {"inverted" if inv else "normal  "}: {n:5d} control tokens (offset {off})')


if __name__ == '__main__':
    main()
