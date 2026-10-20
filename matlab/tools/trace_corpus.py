#!/usr/bin/env python3
"""Random-file parity of panama_uav.transport.import_trace against Python.

Generates a seeded corpus of small random OWD trace files (valid and
invalid: headers, comments, blank and whitespace-only rows, comma and
whitespace delimiters, \\n, \\r\\n and \\r row ends, Unicode spaces and
digits, NUL characters, odd numbers, bad column counts, unordered
timestamps, segments and origins, invalid UTF-8), imports each with
Python's import_trace and with the port on Octave from the same source file,
and reports the mismatches:

    python matlab/tools/trace_corpus.py              # 1000 files, seed 1
    python matlab/tools/trace_corpus.py -n 300 -s 7

A file matches when both raise with the same message (Python's exception
text; an IndexError or UnicodeDecodeError counts as its message too), or
both succeed with the same returned metadata and an .npz whose five .npy
members are byte-identical. Messages that quote a non-ASCII value are a
documented divergence (the port escapes every non-ASCII character in the
repr) and are counted separately, not as matches. Outputs go to
matlab/output/trace_corpus/ (gitignored). Needs octave-cli ($OCTAVE).
"""

from __future__ import annotations

import argparse
import json
import os
import random
import struct
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src"))
OUT = ROOT / "matlab" / "output" / "trace_corpus"
OCTAVE = os.environ.get("OCTAVE", "octave-cli")
MEMBERS = ("timestamps", "delays", "sequence", "source_timestamps", "metadata")

SPACES = [" ", " ", " ", "  ", "\t", "\x0b", "\x0c", "\x1f", "\xa0", "\u2003", "\u3000", "\x85"]
GOOD_NUMBERS = ["0", "1", "-0", "+7", "1.5", "5.", ".5", "1e3", "1E-2", "1_000", "2.5_0", "inf",
                "-Infinity", "nan", "\u0663", "\u0661\u0662", "00012", "1e400", " 3", "4 "]
BAD_NUMBERS = ["x", "1e", "1__0", "_1", "1_", "0x10", "", "1,5", "--1", "1.0.0", "'2'", "\u200b1",
               "1\x002", "\x1f1", "é", "inf_", "1j"]


def _number(rng, base, bad):
    if rng.random() < bad:
        return rng.choice(BAD_NUMBERS)
    if rng.random() < 0.05:
        return rng.choice(GOOD_NUMBERS[:9] if bad == 0 else GOOD_NUMBERS)
    return str(base)


def random_trace(rng):
    """Return (bytes, params) for one random trace file. About half are
    'clean' (formatting variations only, so Python accepts most of them);
    the rest also get bad values, broken rows and bad parameters."""
    clean = rng.random() < 0.5
    odd = 0.0 if clean else 1.0                # scales every error-prone choice
    comma = rng.random() < 0.4
    bad = 0.0 if clean else rng.choice([0.0, 0.01, 0.05])
    n = rng.choice([1, 2, 3, 5, 8, 20, 40]) if clean else rng.choice([0, 1, 2, 3, 5, 8, 20, 40])
    lines = []
    if rng.random() < 0.15:
        lines.append("# " + rng.choice(["trace", "owd, ns", "a,b"][:1 + 2 * int(odd or comma)]))
    if rng.random() < 0.3:
        lines.append(rng.choice(["seq_nr ul_t0 owd_t0_t1", "seq_nr dl_t0 owd_t0_t1",
                                 "seq_nr ul_t0 owd_t0_t1", "seq_nr t0 owd_t0_t1"][:3 + int(odd)]).split())
    t = rng.choice([0, 5_000, 1_700_000_000_000_000_000])
    seq = rng.randrange(0, 1000)
    for _ in range(n):
        seq += 1 + (rng.random() < 0.1)
        t += rng.choice([80_000_000, 125_000, 1, 0]) if rng.random() > 0.01 * odd else -1000
        d = rng.randrange(0, 60_000_000) if rng.random() > 0.01 * odd else -5
        stamp = str(t) if clean else _number(rng, t, bad)      # clean files stay ordered
        fields = [_number(rng, seq, bad / 2), stamp, _number(rng, d, bad)]
        if rng.random() < 0.01 * odd:
            fields = fields[:2] if rng.random() < 0.5 else fields + ["9"]
        if rng.random() < 0.02:
            fields[0] += "\x00"
        lines.append(fields)
        if rng.random() < 0.03:
            lines.append(rng.choice(["", "", "# c", "#,", "   ", "\t"][:4 if comma and clean else 6]))
    out = []
    for item in lines:
        if isinstance(item, str):
            out.append(item)
            continue
        if comma:
            sep = rng.choice([",", ",", ", ", " ,"])
            text = sep.join(item)
        else:
            text = rng.choice(SPACES[:3]) if rng.random() < 0.1 else ""
            for j, f in enumerate(item):
                text += f + (rng.choice(SPACES) if j < len(item) - 1 else "")
        if rng.random() < 0.08:
            text += " # tail" + ("," if rng.random() < 0.5 * (odd or comma) else "")
        out.append(text)
    ends = rng.choice([["\n"], ["\r\n"], ["\r"], ["\n", "\r\n", "\r"]])
    body = ""
    for k, line in enumerate(out):
        body += line
        if k < len(out) - 1 or rng.random() < 0.8:
            body += rng.choice(ends)
    if rng.random() < 0.03:
        body = "\ufeff" + body
    if rng.random() < 0.03 * odd and out:
        body = body.replace("\n", "\x0c", 1)
    raw = body.encode("utf-8")
    if rng.random() < 0.02 * odd:
        raw += rng.choice([b"\xff", b"\xc3", b"\xed\xa0\x80"])
    params = {"direction": "uplink" if rng.random() < 1 - 0.03 * odd else "up",
              "unit": rng.choice(["ns", "ns", "us", "ms", "s"]) if rng.random() < 1 - 0.02 * odd else "min",
              "start": None, "stop": None, "origin": None}
    scale = {"ns": 1e-9, "us": 1e-6, "ms": 1e-3, "s": 1.0, "min": 1.0}[params["unit"]]
    if rng.random() < 0.3:
        params["start"] = (t - rng.choice([0, 80_000_000, 10**12][:2 + int(odd)])) * scale
    if rng.random() < 0.3:
        params["stop"] = (t - rng.choice([0, 160_000_000, 10**12][:2 + int(odd)])) * scale
    if rng.random() < 0.3:
        params["origin"] = rng.choice([0.0, -1.0, t * scale, 1e30][:2 + 2 * int(odd)])
    return raw, params


def python_import(src, out, p):
    from panama_uav.transport import import_trace
    try:
        meta = import_trace(src, out, p["direction"], p["unit"], start=p["start"], end=p["stop"],
                            origin_seconds=p["origin"])
        return {"ok": True, "metadata": meta}
    except Exception as exc:  # noqa: BLE001 - every exception is a verdict
        return {"ok": False, "type": type(exc).__name__, "message": str(exc)}


def _same_metadata(port, python):
    """The returned metadata: floats to 1e-15 relative (Octave's jsonencode
    prints 15 significant digits; the stored JSON member is compared byte
    for byte instead), column_names [] for None, everything else exact."""
    if set(port) != set(python):
        return False
    for key, want in python.items():
        got = port[key]
        if isinstance(want, float):
            if not isinstance(got, (int, float)) or abs(got - want) > 1e-15 * max(1.0, abs(want)):
                return False
        elif want is None:
            if got not in (None, []):
                return False
        elif got != want:
            return False
    return True


def members(path):
    with zipfile.ZipFile(path) as z:
        return {name: z.read(name + ".npy") for name in MEMBERS}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("-n", type=int, default=1000)
    ap.add_argument("-s", "--seed", type=int, default=1)
    args = ap.parse_args(argv)
    rng = random.Random(args.seed)
    for sub in ("src", "py", "m"):
        (OUT / sub).mkdir(parents=True, exist_ok=True)
    corpus = []
    for k in range(args.n):
        raw, params = random_trace(rng)
        src = OUT / "src" / f"{k:05d}.txt"
        src.write_bytes(raw)
        verdict = python_import(src, OUT / "py" / f"{k:05d}.npz", params)
        # Bounds as IEEE bits: Octave's jsondecode can round a decimal 1 ulp off.
        bits = {key: (None if params[key] is None else struct.pack(">d", params[key]).hex())
                for key in ("start", "stop", "origin")}
        corpus.append({"source": str(src), "output": str(OUT / "m" / f"{k:05d}.npz"),
                       "params": {**params, **bits}, "python": verdict})
    (OUT / "corpus.json").write_text(json.dumps(corpus, default=str))
    results = OUT / "results.jsonl"
    cmd = [OCTAVE, "--no-gui", "--eval",
           f"addpath('{ROOT / 'matlab'}'); addpath('{ROOT / 'matlab' / 'tools'}'); "
           f"trace_corpus_check('{OUT / 'corpus.json'}', '{results}');"]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
    got = [json.loads(line) for line in results.read_text().splitlines()]
    tally = {"match": 0, "repr_divergence": 0, "mismatch": 0}
    report = []
    for k, (case, m) in enumerate(zip(corpus, got)):
        py = case["python"]
        if not py["ok"]:
            same = (not m["ok"]) and m["message"] == py["message"]
            quoted = "np.str_(" in py["message"] and any(ord(c) > 127 for c in py["message"])
            if same:
                tally["match"] += 1
            elif quoted and not m["ok"] and m["message"].split("np.str_(")[0] == py["message"].split("np.str_(")[0]:
                tally["repr_divergence"] += 1
            else:
                tally["mismatch"] += 1
                report.append(f"{k}: python {py['type']}: {py['message']!r} vs port {m}")
            continue
        if not m["ok"]:
            tally["mismatch"] += 1
            report.append(f"{k}: python ok vs port error {m['message']!r}")
            continue
        out_py = members(OUT / "py" / f"{k:05d}.npz")
        out_m = members(case["output"])
        diff = [name for name in MEMBERS if out_py[name] != out_m[name]]
        meta_same = _same_metadata(json.loads(m["metadata"]), py["metadata"])
        if diff or not meta_same:
            tally["mismatch"] += 1
            report.append(f"{k}: members differ {diff}, metadata same {meta_same}")
        else:
            tally["match"] += 1
    (OUT / "report.txt").write_text("\n".join(report) + "\n")
    errors = sum(1 for c in corpus if not c["python"]["ok"])
    print(f"{args.n} files (seed {args.seed}), {errors} rejected by Python: "
          f"{tally['match']} match, {tally['repr_divergence']} repr divergences, "
          f"{tally['mismatch']} mismatches (details in {OUT / 'report.txt'})")
    return 0 if tally["mismatch"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
