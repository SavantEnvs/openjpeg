#!/usr/bin/env python3
"""Tiny netpbm (P5/P6) helper for mayhem/test.sh. Exit 0 iff the asserted property holds."""
import sys


def read(path):
    d = open(path, "rb").read()
    pos, toks = 0, []
    while len(toks) < 4:
        while d[pos:pos + 1].isspace():
            pos += 1
        if d[pos:pos + 1] == b"#":
            while d[pos:pos + 1] != b"\n":
                pos += 1
            continue
        s = pos
        while not d[pos:pos + 1].isspace():
            pos += 1
        toks.append(d[s:pos])
    pos += 1
    magic, w, h, maxv = toks[0], int(toks[1]), int(toks[2]), int(toks[3])
    ch = {b"P5": 1, b"P6": 3}[magic]
    bps = 2 if maxv > 255 else 1
    body = d[pos:]
    assert len(body) == w * h * ch * bps, "truncated pixel data"
    return magic, w, h, maxv, ch * bps, body


def main(argv):
    cmd = argv[1]
    if cmd == "same":
        assert read(argv[2]) == read(argv[3]), "pixels differ"
    elif cmd == "dims":
        _, w, h, *_ = read(argv[2])
        assert (w, h) == (int(argv[3]), int(argv[4])), "dims %dx%d" % (w, h)
    elif cmd == "crop":
        _, W, H, _, px, a = read(argv[2])
        _, w, h, _, _, b = read(argv[3])
        x0, y0, x1, y1 = map(int, argv[4:8])
        assert (w, h) == (x1 - x0, y1 - y0), "crop dims %dx%d" % (w, h)
        exp = b"".join(a[(y * W + x0) * px:(y * W + x1) * px] for y in range(y0, y1))
        assert b == exp, "window pixels differ"
    elif cmd == "lossy":
        _, _, _, _, _, a = read(argv[2])
        _, _, _, _, _, b = read(argv[3])
        assert len(a) == len(b), "size"
        err = sum(abs(x - y) for x, y in zip(a, b)) / len(a)
        assert 0 < err < float(argv[4]), "mean abs error %r not in (0,%s)" % (err, argv[4])
    elif cmd == "mean":
        _, _, _, _, _, a = read(argv[2])
        _, _, _, _, _, b = read(argv[3])
        ma, mb = sum(a) / len(a), sum(b) / len(b)
        assert abs(ma - mb) < float(argv[4]), "means %r vs %r" % (ma, mb)
    else:
        raise SystemExit("unknown command " + cmd)


try:
    main(sys.argv)
except AssertionError as e:
    print(e, file=sys.stderr)
    sys.exit(1)
