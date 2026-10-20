#!/usr/bin/env python3
"""Report fragment options that did not end up in the generated .config.

Usage: check-lean-config.py FRAGMENT .config
"""
import re
import sys


def main(frag, config):
    want = {}
    for line in open(frag):
        line = line.strip()
        if line.startswith("CONFIG_"):
            k, v = line.split("=", 1)
            want[k] = v
    have = {}
    for line in open(config):
        m = re.match(r"(CONFIG_\w+)=(.*)", line)
        if m:
            have[m.group(1)] = m.group(2)
        m = re.match(r"# (CONFIG_\w+) is not set", line)
        if m:
            have[m.group(1)] = "n"
    bad = [(k, v, have.get(k, "<absent>")) for k, v in want.items()
           if have.get(k, "n") != v]
    for b in bad:
        print("MISMATCH %-40s want=%s got=%s" % b)
    print(f"{len(want)} requested, {len(bad)} mismatched; "
          f"{sum(v == 'y' for v in have.values())} =y, "
          f"{sum(v == 'm' for v in have.values())} =m")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:3]))
