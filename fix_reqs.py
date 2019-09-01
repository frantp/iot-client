#!/usr/bin/env python3

import sys


if __name__ == "__main__":
    flags = set(sys.argv)
    for line in sys.stdin:
        frags = line.strip().split("#", maxsplit=1)
        if len(frags) > 1:
            code = frags[1].strip()
            if "no-" + code in flags or \
                ("only" in flags and not code in flags):
                continue
        print(line)
