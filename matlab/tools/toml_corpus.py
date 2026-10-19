#!/usr/bin/env python3
"""Random-document parity of panama_uav.util.toml_decode against tomllib.

Generates a seeded corpus of small random TOML documents (valid and
invalid), records tomllib's verdict for each, decodes every document with
toml_decode on Octave, and reports the mismatch rate:

    python matlab/tools/toml_corpus.py              # 3000 documents, seed 1
    python matlab/tools/toml_corpus.py -n 500 -s 7

A document matches when both accept it with the same canonical value
(make_fixtures.canonical, type-preserving), or both reject it and
toml_decode raises panama_uav:toml at tomllib's location ("line N" or
"end of document"). Everything else is a mismatch: accept/reject
disagreement, a different value, a different location, or a crash with
another error identifier.

The generator stays inside the subset toml_decode documents as supported:
no dates/times, multiline strings or \\uXXXX escapes, bare keys that are
valid MATLAB field names, and integers inside int64 (out-of-range integers
are a deliberate divergence, tested in TomlTest). Outputs go to
matlab/output/toml_corpus/ (gitignored): corpus.json, results.txt and
report.txt with every mismatch. Needs octave-cli (override with $OCTAVE).
"""

from __future__ import annotations

import argparse
import json
import os
import random
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
OUT = ROOT / "matlab" / "output" / "toml_corpus"
OCTAVE = os.environ.get("OCTAVE", "octave-cli")

KEYS = ["a", "b", "c", "d", "x_1", "k"]
BAD_NUMBERS = ["-", "+", "1.", "1__0", "_1", "01", ".5", "1e", "-0x1", "0x", "inf_", "1.e5", "0X1"]
STRING_CHARS = list("abc xyz019_-.#=[]{},") + ["é", "ü", "π", "\\n", "\\t", '\\"', "\\\\"]


def canonical(value):
    import math
    if isinstance(value, dict):
        return "{" + ",".join(f"{k}:{canonical(v)}" for k, v in value.items()) + "}"
    if isinstance(value, list):
        return "[" + ",".join(canonical(v) for v in value) + "]"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return f"i{value}"
    if isinstance(value, str):
        return f"s{len(value)}:{value}"
    if isinstance(value, float):
        if math.isinf(value):
            return "finf" if value > 0 else "f-inf"
        if math.isnan(value):
            return "fnan"
        return "f" + format(value, ".17g")
    raise TypeError(type(value))


class Gen:
    def __init__(self, rng):
        self.r = rng

    def key(self):
        parts = [self.r.choice(KEYS) for _ in range(self.r.choice([1, 1, 1, 2, 2, 3]))]
        if self.r.random() < 0.1:
            i = self.r.randrange(len(parts))
            parts[i] = f'"{parts[i]}"'
        return ".".join(parts)

    def integer(self):
        r = self.r.random()
        if r < 0.05:
            return self.r.choice(BAD_NUMBERS)
        if r < 0.15:
            return self.r.choice(["0xff", "0xDEAD_beef", "0o17", "0b101", "0x7FFFFFFFFFFFFFFF"])
        n = self.r.choice([0, 1, 7, 42, 1000, 123456789, 9223372036854775807])
        text = f"{n:_}" if self.r.random() < 0.2 else str(n)
        if self.r.random() < 0.3:
            text = self.r.choice("+-") + text
        return text

    def floating(self):
        return self.r.choice(["1.5", "-0.25", "1e5", "-2E-3", "3.0e+2", "+inf", "-inf", "nan",
                              "0.0", "-0.0", "6.02_2e23", "1_000.5"])

    def string(self):
        body = "".join(self.r.choice(STRING_CHARS) for _ in range(self.r.randrange(0, 6)))
        if self.r.random() < 0.3:
            return "'" + body.replace("'", "").replace("\\", "/") + "'"
        if self.r.random() < 0.03:
            return '"' + body                       # unterminated
        return '"' + body + '"'

    def value(self, depth=0):
        r = self.r.random()
        if depth < 2 and r < 0.15:
            items = [self.value(depth + 1) for _ in range(self.r.randrange(0, 4))]
            sep = self.r.choice([", ", ",", ",\n  "]) if depth == 0 else ", "
            tail = "," if items and self.r.random() < 0.2 else ""
            return "[" + sep.join(items) + tail + "]"
        if depth < 2 and r < 0.35:
            pairs = [f"{self.key()} = {self.value(depth + 1)}" for _ in range(self.r.randrange(0, 4))]
            return "{" + ", ".join(pairs) + "}"
        if r < 0.55:
            return self.integer()
        if r < 0.7:
            return self.floating()
        if r < 0.8:
            return self.r.choice(["true", "false"])
        return self.string()

    def document(self):
        lines = []
        for _ in range(self.r.randrange(1, 7)):
            r = self.r.random()
            if r < 0.15:
                lines.append(f"[{self.key()}]")
            elif r < 0.22:
                lines.append(f"[[{self.key()}]]")
            elif r < 0.27:
                lines.append("# " + self.string())
            elif r < 0.3:
                lines.append("")
            else:
                stmt = f"{self.key()} = {self.value()}"
                if self.r.random() < 0.1:
                    stmt += " # note"
                lines.append(stmt)
        eol = self.r.choices(["\n", "\r\n", "\r"], weights=[85, 12, 3])[0]
        text = eol.join(lines)
        if self.r.random() < 0.6:
            text += eol
        return text


def location(exc):
    text = str(exc)
    if "(at end of document)" in text:
        return "end of document"
    return "line " + text.rsplit("(at line ", 1)[1].split(",", 1)[0]


def build(n, seed):
    gen = Gen(random.Random(seed))
    docs = []
    for _ in range(n):
        text = gen.document()
        try:
            docs.append({"text": text, "accepted": True, "canonical": canonical(tomllib.loads(text))})
        except tomllib.TOMLDecodeError as exc:
            docs.append({"text": text, "accepted": False, "location": location(exc), "message": str(exc)})
    return docs


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=3000)
    ap.add_argument("-s", "--seed", type=int, default=1)
    args = ap.parse_args(argv)
    OUT.mkdir(parents=True, exist_ok=True)
    docs = build(args.n, args.seed)
    (OUT / "corpus.json").write_text(json.dumps({"docs": docs}), encoding="utf-8")
    results = OUT / "results.txt"
    script = (f"addpath('{ROOT / 'matlab'}'); addpath('{ROOT / 'matlab' / 'tools'}'); "
              f"toml_corpus_check('{OUT / 'corpus.json'}', '{results}');")
    subprocess.run([OCTAVE, "--no-gui", "--eval", script], check=True, cwd=ROOT)
    statuses = results.read_text(encoding="utf-8").splitlines()
    assert len(statuses) == len(docs), (len(statuses), len(docs))
    bad = [(i, s) for i, s in enumerate(statuses) if s != "ok"]
    kinds = {}
    for _, s in bad:
        kinds[s.split(":", 1)[0]] = kinds.get(s.split(":", 1)[0], 0) + 1
    accepted = sum(d["accepted"] for d in docs)
    lines = [f"documents: {len(docs)} (seed {args.seed}); tomllib accepts {accepted}, rejects {len(docs) - accepted}",
             f"mismatches: {len(bad)} ({100 * len(bad) / len(docs):.2f}%)"]
    lines += [f"  {k}: {v}" for k, v in sorted(kinds.items())]
    for i, s in bad:
        d = docs[i]
        lines.append(f"--- #{i} {s}\n{d['text']!r}\n    tomllib: "
                     + (d["canonical"] if d["accepted"] else f"reject at {d['location']}: {d['message']}"))
    (OUT / "report.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines[:2 + len(kinds)]))
    print(f"written {(OUT / 'report.txt').relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
