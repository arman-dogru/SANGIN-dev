#!/usr/bin/env python3
"""Disable validation rules one at a time and check that a MATLAB test fails.

Measures, rather than asserts, that the parity tests cover each rule. For
every mutant the working tree is copied to a temporary directory (the
repository itself is never modified), one rule is disabled, and the named
Octave test files run there. A mutant is *killed* when a test fails, the
run errors, or it times out; it *survives* when every test still passes.

    python matlab/tools/mutation_sweep.py              # all groups
    python matlab/tools/mutation_sweep.py config       # one group
    python matlab/tools/mutation_sweep.py --list       # list mutants only

Groups: config (the 20 load_config / validate_transport / overlay rules,
run against ConfigTest), toml (toml_decode's rejection and location rules,
TomlTest) and env (start/goal pop order, RngTest). The summary is printed
and written to matlab/output/mutation_sweep.txt, which is gitignored.
Exit status is 0 only when every mutant is killed and the unmutated
baseline passes. Needs octave-cli (override with $OCTAVE).
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OCTAVE = os.environ.get("OCTAVE", "octave-cli")
TIMEOUT = 300

LOAD = "matlab/+panama_uav/+config/load_config.m"
TRANSPORT = "matlab/+panama_uav/+config/validate_transport.m"
OVERLAY = "matlab/+panama_uav/+config/overlay.m"
TOML = "matlab/+panama_uav/+util/toml_decode.m"
POP = "matlab/+panama_uav/+environment/pop_starts_and_goals.m"


def drop(marker):
    """Remove the error(...)/err(...)/fail(...) statement containing MARKER."""
    return ("drop", marker)


def swap(old, new):
    return ("swap", old, new)


# (group, name, file, mutation). Every config entry is one study rule.
MUTANTS = [
    ("config", "legacy or unknown section", LOAD, drop("Legacy or unknown configuration sections")),
    ("config", "fixed ladder 2/4/6/8", LOAD, drop("Study requires fixed map")),
    ("config", "validation schedule", LOAD, drop("Study requires 200 validation episodes")),
    ("config", "reward and map unchanged", LOAD, drop("This study retains 0.1 task rewards")),
    ("config", "budget in (0, 24 h]", LOAD, drop("A condition allocation must be positive")),
    ("config", "unknown option (dataclass TypeError)", OVERLAY, drop("Unknown %s option")),
    ("config", "communication profile", TRANSPORT, drop("Unknown communication profile")),
    ("config", "mission route", TRANSPORT, drop("Unknown mission route")),
    ("config", "stale information", TRANSPORT, drop("Unknown stale information")),
    ("config", "simulated time", TRANSPORT, drop("Invalid simulated time")),
    ("config", "backhaul offset", TRANSPORT, drop("Backhaul timeline offset")),
    ("config", "packet sizes", TRANSPORT, drop("Invalid packet sizes")),
    ("config", "scheduling frame", TRANSPORT, drop("Invalid scheduling frame")),
    ("config", "orbital replay needs timeline", TRANSPORT, drop("Orbital replay requires")),
    ("config", "model distribution", TRANSPORT, drop("Unknown model distribution route")),
    ("config", "timeline/trace double count", TRANSPORT, drop("do not double-count")),
    ("config", "one or two windows", TRANSPORT, drop("Use one or two reservation windows")),
    ("config", "reservation duration", TRANSPORT, drop("Invalid reservation duration")),
    ("config", "capacity", TRANSPORT, drop("Capacity must be positive")),
    ("config", "physical delays", TRANSPORT, drop("Invalid physical delays")),
    ("toml", "number grammar: reject invalid token", TOML,
     swap("        fail(p, ['invalid value ', raw]);", "        kind = 'float';")),
    ("toml", "number grammar: leading zeros / bare sign", TOML,
     swap("    dec = '[+-]?(0|[1-9](_?[0-9])*)';", "    dec = '[+-]?[0-9_]*';")),
    ("toml", "number grammar: underscores between digits", TOML,
     swap("    digits = '[0-9](_?[0-9])*';", "    digits = '[0-9_]+';")),
    ("toml", "number grammar: digits after '.'", TOML,
     swap("[dec, '(\\.', digits,", "[dec, '(\\.[0-9_]*', '',")),
    ("toml", "number grammar: no sign on 0x/0o/0b", TOML,
     swap("is_match(raw, '0x[", "is_match(raw, '[+-]?0x[")),
    ("toml", "[[t]] over a value", TOML, drop("cannot mutate an immutable value with")),
    ("toml", "[[t]] over a table", TOML, drop("cannot overwrite a table with")),
    ("toml", "[t] declared twice", TOML, drop("cannot declare a table twice")),
    ("toml", "duplicate inline key", TOML, drop("duplicate inline table key")),
    ("toml", "dotted key into inline/aot", TOML, drop("cannot mutate an immutable namespace')")),
    ("toml", "dotted key into a [table]", TOML, drop("cannot redefine a namespace")),
    ("toml", "duplicate key", TOML,
     swap("        fail(p, 'cannot overwrite a value');\n    end\n    if isstruct(value)",
          "    end\n    if isstruct(value)")),
    ("toml", "error line counts newlines before p.i", TOML,
     swap("line = sum(p.s(1:p.i - 1) == char(10)) + 1;", "line = sum(p.s(1:p.i) == char(10)) + 1;")),
    ("toml", "'end of document' past the real text", TOML,
     swap("    if p.i >= numel(p.s)           % past the real text",
          "    if p.i > numel(p.s)           % past the real text")),
    ("env", "odd agent start/goal order", POP,
     swap("        starts(end + 1, :) = cells(end, :);\n        goals(end + 1, :) = cells(end - 1, :);",
          "        starts(end + 1, :) = cells(end - 1, :);\n        goals(end + 1, :) = cells(end, :);")),
    ("env", "pair goals swapped", POP,
     swap("goals = [goals; second; first];", "goals = [goals; first; second];")),
]

# Equivalent mutants are left out: a separate "dotted key through a value"
# prefix check was removed from toml_decode because the final lookup in
# check_assign already rejects it (the sweep showed it could not be killed).

TESTS = {"config": "Config", "toml": "Toml", "env": "Rng"}


def apply(text, mutation):
    if mutation[0] == "swap":
        _, old, new = mutation
        if text.count(old) != 1:
            raise SystemExit(f"mutation anchor not unique ({text.count(old)}): {old!r}")
        return text.replace(old, new, 1)
    marker = mutation[1]
    if text.count(marker) != 1:
        raise SystemExit(f"marker not unique ({text.count(marker)}): {marker!r}")
    at = text.index(marker)
    starts = [m.start() for m in re.finditer(r"\b(error|err|fail)\(", text[:at])]
    start = starts[-1]
    end = text.index(");", at) + 2
    return text[:start] + "% rule disabled by mutation_sweep" + text[end:]


def copy_tree(dest):
    ignore = shutil.ignore_patterns(".git", "output", "__pycache__", ".venv", "*.asv", "octave-workspace")
    shutil.copytree(ROOT, dest, ignore=ignore, symlinks=True)


def run_tests(tree, pattern):
    cmd = [OCTAVE, "--no-gui", "--eval", f"cd matlab; ok = run_tests('{pattern}'); exit(~ok)"]
    try:
        res = subprocess.run(cmd, cwd=tree, capture_output=True, text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "timeout", "timeout"
    out = res.stdout + res.stderr
    m = re.search(r"(\d+) passed, (\d+) failed", out)
    summary = f"{m.group(1)} passed, {m.group(2)} failed" if m else "no summary (run errored)"
    return ("pass" if res.returncode == 0 and m and m.group(2) == "0" else "fail"), summary


def main(argv):
    groups = [a for a in argv if not a.startswith("-")] or list(TESTS)
    chosen = [m for m in MUTANTS if m[0] in groups]
    if "--list" in argv:
        for g, name, path, _ in chosen:
            print(f"{g:7} {name:45} {path}")
        return 0
    lines = []
    ok = True
    with tempfile.TemporaryDirectory(prefix="mutation_sweep_") as tmp:
        tree = Path(tmp) / "repo"
        copy_tree(tree)
        for group in groups:
            status, summary = run_tests(tree, TESTS[group])
            lines.append(f"baseline {group:7} {TESTS[group]}Test: {summary}")
            print(lines[-1], flush=True)
            if status != "pass":
                ok = False
        for group, name, path, mutation in chosen:
            target = tree / path
            original = target.read_text(encoding="utf-8")
            target.write_text(apply(original, mutation), encoding="utf-8")
            t0 = time.time()
            status, summary = run_tests(tree, TESTS[group])
            target.write_text(original, encoding="utf-8")
            verdict = "SURVIVED" if status == "pass" else "killed"
            ok = ok and verdict == "killed"
            lines.append(f"{verdict:8} {group:7} {name:45} {summary} ({time.time() - t0:.0f} s)")
            print(lines[-1], flush=True)
    for group in groups:
        sub = [line for line in lines if line.split()[1:2] == [group] and not line.startswith("baseline")]
        killed = sum(line.startswith("killed") for line in sub)
        lines.append(f"{group}: {killed}/{len(sub)} killed")
        print(lines[-1])
    out = ROOT / "matlab" / "output" / "mutation_sweep.txt"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"written {out.relative_to(ROOT)}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
