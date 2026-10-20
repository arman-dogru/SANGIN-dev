#!/usr/bin/env python3
"""Disable validation rules one at a time and check that a MATLAB test fails.

Measures, rather than asserts, that the parity tests cover each rule. For
every mutant the working tree is copied to a temporary directory (the
repository itself is never modified), one rule is disabled, and the named
Octave test files run there. Each mutant is reported as
*killed* (a verify/assert failed), *ERRORED* (no assertion failed, but a
test raised an unexpected exception or the run crashed), *TIMEOUT* or
*SURVIVED* (every test passed). Only assertion kills count as coverage.
A run with both assertion failures and errors counts as killed: at least
one verify/assert caught the mutant (the summary shows both counts).

    python matlab/tools/mutation_sweep.py              # all groups
    python matlab/tools/mutation_sweep.py config       # one group
    python matlab/tools/mutation_sweep.py --list       # list mutants only

Groups: config (the 20 load_config / validate_transport / overlay rules,
run against ConfigTest), toml (toml_decode's rejection and location rules,
TomlTest), env (start/goal pop order, RngTest), encode (pickle size rules,
including the mission-payload types PyDict, PyInstance and PyTupleRows,
EncodeTest), mission (the Python shapes of the mission payloads in
mission_wire, InformationTest), rollout (MissionCommunication sending
those sizes, two physical-profile rollouts of EnvironmentParityTest),
npy (.npy files written by NumPy, NpyTest), trace (.npz reader and
DelayTrace, TraceTest), trace_import (import_trace parsing and checks,
the .npy/.npz writers and Python's float repr, ImportTraceTest), records
(portable SHA-256, RecordsTest) and transport (physical link service,
handovers, trace replay, byte counters and occupancy, TransportTest).
Groups with several test patterns run them in one Octave session and add
up their counts. The summary is printed
and written to matlab/output/mutation_sweep.txt, which is gitignored.
Exit status is 0 only when the unmutated baseline passes and every mutant
is killed by an assertion (ERRORED, TIMEOUT and SURVIVED all fail it).
Needs octave-cli (override with $OCTAVE).
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
UTF8 = "matlab/+panama_uav/+util/decode_utf8.m"
READ = "matlab/+panama_uav/+util/read_text.m"
ENCODE = "matlab/+panama_uav/+transport/encode_size.m"
TRANSPORT_M = "matlab/+panama_uav/+transport/Transport.m"
TRACE = "matlab/+panama_uav/+transport/DelayTrace.m"
NPY = "matlab/+panama_uav/+util/read_npy.m"
WIRE = "matlab/+panama_uav/+information/mission_wire.m"
MISSION = "matlab/+panama_uav/+information/MissionCommunication.m"
IMPORT = "matlab/+panama_uav/+transport/import_trace.m"
NPY_W = "matlab/+panama_uav/+util/npy_bytes.m"
NPZ_W = "matlab/+panama_uav/+util/write_npz.m"
REPR = "matlab/+panama_uav/+util/py_float_repr.m"
SHA = "matlab/+panama_uav/+util/sha256_bytes.m"


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
    ("toml", "namespace tracking inside inline tables", TOML,
     swap("        [st, p] = check_assign(value, {}, keys, item, st, p);\n", "")),
    ("toml", "decimal int64 range", TOML,
     swap("    ok = numel(digits) < numel(limit) || (numel(digits) == numel(limit) && string_le(digits, limit));",
          "    ok = true;")),
    ("toml", "0x/0o/0b int64 range", TOML,
     swap("    ok = numel(digits) < w || (numel(digits) == w && (base ~= 16 || lower(digits(1)) <= '7'));",
          "    ok = true;")),
    ("toml", "bare carriage return", TOML,
     swap("    if p.i + 1 < numel(p.s) && p.s(p.i + 1) == char(10)", "    if true")),
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
    ("toml", "control characters in strings and quoted keys", TOML,
     swap("        if is_control(c)                   % includes CR", "        if false")),
    ("toml", "control characters in comments", TOML,
     swap("        if is_control(p.s(p.i))", "        if false")),
    ("toml", "U+007F is a control character", TOML,
     swap("tf = (v < 32 && v ~= 9) || v == 127;", "tf = (v < 32 && v ~= 9);")),
    ("toml", "utf-8: invalid start byte", UTF8,
     swap("            fail(bytes, i, i, 'invalid start byte');", "            need = 0; lo = 0; hi = 0;")),
    ("toml", "utf-8: C0/C1 overlong 2-byte forms", UTF8,
     swap("if b >= 194 && b <= 223", "if b >= 192 && b <= 223")),
    ("toml", "utf-8: E0 overlong 3-byte forms", UTF8,
     swap("if b == 224, lo = 160;", "if b == 224, lo = 128;")),
    ("toml", "utf-8: ED surrogates", UTF8,
     swap("elseif b == 237, hi = 159;", "elseif b == 237, hi = 191;")),
    ("toml", "utf-8: F0 overlong 4-byte forms", UTF8,
     swap("if b == 240, lo = 144;", "if b == 240, lo = 128;")),
    ("toml", "utf-8: F4 above U+10FFFF", UTF8,
     swap("elseif b == 244, hi = 143;", "elseif b == 244, hi = 191;")),
    ("toml", "utf-8: truncated sequence", UTF8,
     swap("                fail(bytes, i, i + j - 1, 'unexpected end of data');", "                break;")),
    ("toml", "utf-8: continuation bytes", UTF8,
     swap("            if ~ok\n                fail(bytes, i, i + j - 1, 'invalid continuation byte');",
          "            if false\n                fail(bytes, i, i + j - 1, 'invalid continuation byte');")),
    ("toml", "read_text validates UTF-8", READ,
     swap("    text = panama_uav.util.decode_utf8(bytes);", "    text = char(bytes);")),
    # encode: pickle protocol-5 size rules (EncodeTest)
    ("encode", "BININT1 up to 255", ENCODE, swap("if x >= 0 && x <= 255", "if x >= 0 && x <= 256")),
    ("encode", "BININT2 up to 65535", ENCODE, swap("elseif x >= 0 && x <= 65535", "elseif x >= 0 && x <= 65536")),
    ("encode", "BININT for signed 32-bit", ENCODE,
     swap("small = w >= int64(-2147483648) && w <= int64(2147483647);",
          "small = w >= int64(-2147483647) && w <= int64(2147483647);")),
    ("encode", "LONG1 byte count", ENCODE, swap("nbytes = floor(nbits / 8) + 1;", "nbytes = ceil(nbits / 8);")),
    ("encode", "LONG1 drops sign byte of -(2**(8j-1))", ENCODE,
     swap("if negative && power_of_two && mod(nbits, 8) == 0", "if false")),
    ("encode", "SHORT_BINUNICODE up to 255 bytes", ENCODE,
     swap("        if m <= 255\n", "        if m < 255\n")),
    ("encode", "str length in UTF-8 bytes", ENCODE,
     swap("m = numel(c);                            % Octave char holds UTF-8 bytes",
          "m = panama_uav.util.text_length(v);")),
    ("encode", "SHORT_BINBYTES up to 255 bytes", ENCODE, swap("if v.n <= 255", "if v.n < 255")),
    ("encode", "TUPLE1/2/3 for short tuples", ENCODE, swap("        elseif k <= 3\n            for j = 1:k", "        elseif k <= 4\n            for j = 1:k")),
    ("encode", "tuple rows: TUPLE1/2/3 up to 3 items", ENCODE,
     swap("    elseif k <= 3\n        tuple_extra = 1;", "    elseif k <= 4\n        tuple_extra = 1;")),
    ("encode", "list of one: APPEND", ENCODE,
     swap("        if k == 1\n            s = save(s, v{1});", "        if false\n            s = save(s, v{1});")),
    ("encode", "list batches of 1000", ENCODE,
     swap("s = save(s, v{total});\n                    batch = batch + 1;\n                    if batch == 1000",
          "s = save(s, v{total});\n                    batch = batch + 1;\n                    if batch == 2000")),
    ("encode", "dict of one: SETITEM", ENCODE,
     swap("    if k == 1\n        s = save(s, keys{1});", "    if false\n        s = save(s, keys{1});")),
    ("encode", "dict extra empty batch after a full one", ENCODE,
     swap("        while batch == 1000\n", "        while pos < k\n")),
    ("encode", "FRAME header is 9 bytes", ENCODE,
     swap("s.len = s.len + 9;                       % FRAME header, reserved",
          "s.len = s.len + 8;                       % FRAME header, reserved")),
    ("encode", "frames under 4 bytes lose their header", ENCODE,
     swap("if s.len - s.fs - 9 < 4", "if s.len - s.fs - 9 < 5")),
    ("encode", "frame commit at 64 KiB opcode boundaries", ENCODE,
     swap("if s.framing && s.fs >= 0 && s.len - s.fs - 9 >= 65536", "if false")),
    ("encode", "64 KiB payloads bypass the frame", ENCODE,
     swap("    if k >= 65536\n        s = commit(s);", "    if k > 65536\n        s = commit(s);")),
    ("encode", "no frame around a bypassed payload", ENCODE,
     swap("        s.framing = false;\n        s = write(s, header);", "        s = write(s, header);")),
    ("encode", "uint64 up to 2**31 - 1 is a BININT", ENCODE,
     swap("small = v <= uint64(2147483647);", "small = false;")),
    # encode, M1b-2: mission-payload types (EncodeTest)
    ("encode", "PyDict keys saved as their own type", ENCODE,
     swap("        s = save_dict(s, v.keys, v.values);",
          "        s = save_dict(s, cellfun(@(k) 0.5, v.keys, 'UniformOutput', false), v.values);")),
    ("encode", "instance: class as module and qualname", ENCODE,
     swap("        s = save(s, v.module);\n", "")),
    ("encode", "instance: STACK_GLOBAL", ENCODE,
     swap("        s = write(s, 1);                         % STACK_GLOBAL", "")),
    ("encode", "instance: empty argument tuple", ENCODE,
     swap("        s = write(s, 1);                         % EMPTY_TUPLE", "")),
    ("encode", "instance: NEWOBJ", ENCODE,
     swap("        s = write(s, 1);                         % NEWOBJ", "")),
    ("encode", "instance: BUILD after the state", ENCODE,
     swap("        s = write(s, 1);                         % BUILD", "")),
    ("encode", "tuple rows: BININT1 up to 255", ENCODE,
     swap("sizes(x >= 0 & x <= 255) = 2;", "sizes(x >= 0 & x <= 256) = 2;")),
    ("encode", "tuple rows: BININT2 up to 65535", ENCODE,
     swap("sizes(x >= 0 & x <= 65535) = 3;", "sizes(x >= 0 & x <= 65536) = 3;")),
    ("encode", "tuple rows: LONG1 beyond signed 32-bit", ENCODE,
     swap("wide = find(int64(m) < int64(-2147483648) | int64(m) > int64(2147483647));",
          "wide = find(int64(m) < int64(-2147483649) | int64(m) > int64(2147483647));")),
    ("encode", "tuple rows: MARK ... TUPLE past 3 items", ENCODE,
     swap("        tuple_extra = 2;                         % MARK ... TUPLE", "        tuple_extra = 1;")),
    ("encode", "tuple rows: EMPTY_TUPLE for 0 items", ENCODE,
     swap("        tuple_extra = 1;                         % EMPTY_TUPLE", "        tuple_extra = 0;")),
    ("encode", "tuple rows: one row is EMPTY_LIST, APPEND", ENCODE,
     swap("        list_extra = 2;                          % EMPTY_LIST, APPEND",
          "        list_extra = 3;")),
    ("encode", "tuple rows: batches of 1000", ENCODE,
     swap("list_extra = 1 + 2 * ceil(n / 1000);", "list_extra = 1 + 2 * ceil(n / 2000);")),
    ("encode", "tuple rows: whole-list size only inside one frame", ENCODE,
     swap("    if ~s.framing || held + total <= 65536", "    if true")),
    ("encode", "tuple rows: frame boundary before each int", ENCODE,
     swap("            s = boundary(s);                     % save(int)\n", "")),
    ("encode", "tuple rows: MARK per batch across frames", ENCODE,
     swap("if n > 1 && mod(j - 1, 1000) == 0", "if n > 1 && j == 1")),
    # mission: wire shapes of the mission payloads (InformationTest)
    ("mission", "report position is a tuple of ints", WIRE,
     swap("    t = panama_uav.transport.PyTuple(int64(p(1)), int64(p(2)));",
          "    t = panama_uav.transport.PyTuple(double(p(1)), double(p(2)));")),
    ("mission", "report distance is a float", WIRE,
     swap("'distance', double(r.distance)", "'distance', int64(r.distance)")),
    ("mission", "report completed is a bool", WIRE,
     swap("'completed', logical(r.completed));\nend", "'completed', double(r.completed));\nend")),
    ("mission", "path is a list of tuples", WIRE,
     swap("        'path', panama_uav.transport.PyTupleRows(reshape(r.path, [], 2)), ...",
          "        'path', panama_uav.transport.PyTupleRows(reshape(r.path, [], 1)), ...")),
    ("mission", "reports keyed by int agent id", WIRE,
     swap("            ids = num2cell(int64(0:n - 1));", "            ids = num2cell(double(0:n - 1));")),
    ("mission", "sources map agent to float time", WIRE,
     swap("    d = panama_uav.transport.PyDict(num2cell(int64(ids)), num2cell(double(values)));",
          "    d = panama_uav.transport.PyDict(num2cell(int64(ids)), num2cell(int64(values)));")),
    ("mission", "information keyed by field", WIRE,
     swap("            w = struct(payload.field, item);", "            w = item;")),
    ("mission", "Guidance pickled by its module path", WIRE,
     swap("PyInstance('panama_uav.information', 'Guidance'", "PyInstance('information', 'Guidance'")),
    ("mission", "Guidance state: route and reported_distance", WIRE,
     swap("                'reported_distance', double(v.reported_distance)));",
          "                'distance', double(v.reported_distance)));")),
    ("mission", "intentions: path and completed per peer", WIRE,
     swap("                'completed', logical(x.completed)), v, 'UniformOutput', false);",
          "                'done', logical(x.completed)), v, 'UniformOutput', false);")),
    # rollout: MissionCommunication on the physical profile (EnvironmentParityTest, 2 cases)
    ("rollout", "messages carry Python's wire size", MISSION,
     swap("obj.transport.send(agent, kind, payload, varargin{:}, 'wire_bytes', bytes);",
          "obj.transport.send(agent, kind, payload, varargin{:}, 'wire_bytes', bytes + 1);")),
    ("rollout", "task information sourced from its agent only", MISSION,
     swap("                        ids = packet.agent;\n                        times = packet.generated_at;",
          "                        ids = 0:numel(payload.sources) - 1;\n                        times = payload.sources;")),
    # trace_import: import_trace, npy/npz writers, float repr (ImportTraceTest)
    ("trace_import", "direction required", IMPORT, drop("Direction is required")),
    ("trace_import", "explicit units", IMPORT, drop("Explicit supported units required")),
    ("trace_import", "empty file has no first line", IMPORT,
     swap("    if isempty(text)\n        error(", "    if false\n        error(")),
    ("trace_import", "delimiter from the first line only", IMPORT,
     swap("    comma = any(first == 44);", "    comma = any(text == 44);")),
    ("trace_import", "first line ends at splitlines boundaries", IMPORT,
     swap("    breaks = [10 13 11 12 28 29 30 133 8232 8233];", "    breaks = [10 13];")),
    ("trace_import", "'#' starts a comment", IMPORT,
     swap("        hash = find(line == 35, 1);", "        hash = [];")),
    ("trace_import", "comma mode skips only empty rows", IMPORT,
     swap("            if isempty(line)\n                continue;", "            if all(is_space(line))\n                continue;")),
    ("trace_import", "whitespace is str.isspace", IMPORT,
     swap("(cp >= 28 & cp <= 32) | cp == 133 | cp == 160", "cp == 32 | cp == 133 | cp == 160")),
    ("trace_import", "consistent column count", IMPORT, drop("the number of columns changed")),
    ("trace_import", "three columns", IMPORT, drop("Expected sequence, transmit timestamp")),
    ("trace_import", "str width over the whole file", IMPORT,
     swap("    width = max([1, cellfun(@numel, raw(:))']);", "    width = max([1, cellfun(@numel, raw(:, 1))']);")),
    ("trace_import", "trailing NULs dropped on read-back", IMPORT,
     swap("    k = find(cp ~= 0, 1, 'last');", "    k = numel(cp);")),
    ("trace_import", "header row detected", IMPORT,
     swap("    if size(value, 1) >= 1 && is_text(value{1, 1}, 'seq_nr')", "    if false && is_text(value{1, 1}, 'seq_nr')")),
    ("trace_import", "dl_t0 header accepted", IMPORT,
     swap(" || is_text(value{1, 2}, 'dl_t0')", "")),
    ("trace_import", "header-only file is empty", IMPORT, drop("Empty trace file")),
    ("trace_import", "float: single underscores between digits", IMPORT,
     swap("['^[+-]?(?:inf|infinity|nan|(?:\\d(?:_?\\d)*", "['^[+-]?(?:inf|infinity|nan|(?:\\d[\\d_]*")),
    ("trace_import", "float: non-ASCII spaces stripped", IMPORT,
     swap("    t(t > 127 & is_space(t)) = 32;", "")),
    ("trace_import", "float: Unicode decimal digits", IMPORT,
     swap("    for z = zeros_(2:end)", "    for z = []")),
    ("trace_import", "float: only ASCII whitespace stripped", IMPORT,
     swap("    ascii_space = t == 32 | (t >= 9 & t <= 13);", "    ascii_space = t == 32 | (t >= 9 & t <= 13) | (t >= 28 & t <= 31);")),
    ("trace_import", "float: error repr", IMPORT,
     swap("        elseif c >= 32 && c < 127\n            parts{k} = char(c);",
          "        elseif c >= 0 && c < 127\n            parts{k} = char(c);")),
    ("trace_import", "values finite, delays nonnegative", IMPORT,
     swap(" || any(delays < 0)\n", "\n")),
    ("trace_import", "timestamps ordered", IMPORT, drop("Trace timestamps must be ordered")),
    ("trace_import", "start bound inclusive", IMPORT,
     swap("mask = mask & timestamps >= start_s;", "mask = mask & timestamps > start_s;")),
    ("trace_import", "end bound inclusive", IMPORT,
     swap("mask = mask & timestamps <= end_s;", "mask = mask & timestamps < end_s;")),
    ("trace_import", "empty segment", IMPORT, drop("Empty trace segment")),
    ("trace_import", "origin not after the first sample", IMPORT, drop("Trace origin must not be later")),
    ("trace_import", "default origin is the first kept sample", IMPORT,
     swap("        origin = chosen(1);", "        origin = timestamps(1);")),
    ("trace_import", "unit scale applied by one multiplication", IMPORT,
     swap("    timestamps = timestamps * scale;", "    timestamps = timestamps / (1 / scale);")),
    ("trace_import", ".npz appended to the output name", IMPORT,
     swap("        out = [out, '.npz'];", "        out = out;")),
    ("trace_import", "source sha256 in metadata", IMPORT,
     swap("panama_uav.util.sha256_bytes(bytes), ...", "panama_uav.util.sha256_bytes(uint8([])), ...")),
    ("trace_import", "metadata JSON escapes non-ASCII", IMPORT,
     swap("                if c < 32 || (c > 126 && c < 65536)", "                if c < 32")),
    ("trace_import", "float repr: exponent from 1e16", REPR, swap("if e >= -4 && e < 16", "if e >= -4 && e < 17")),
    ("trace_import", "float repr: exponent below 1e-4", REPR, swap("if e >= -4 && e < 16", "if e >= -5 && e < 16")),
    ("trace_import", "float repr: shortest round trip", REPR, swap("    for p = 1:17\n", "    for p = 17:17\n")),
    ("trace_import", "npy: header padded to 64 bytes", NPY_W,
     swap("    pad = 64 - mod(10 + hlen, 64);", "    pad = 16 - mod(10 + hlen, 16);")),
    ("trace_import", "npy: UTF-32 little-endian", NPY_W,
     swap("body = uint8(reshape([mod(w, 256); mod(floor(w / 256), 256); ...\n                mod(floor(w / 65536), 256); floor(w / 16777216)], 1, []));",
          "body = uint8(reshape([floor(w / 16777216); mod(floor(w / 65536), 256); ...\n                mod(floor(w / 256), 256); mod(w, 256)], 1, []));")),
    ("trace_import", "zip: CRC-32 of each member", NPZ_W,
     swap("    c = bitxor(c, 4294967295);", "    c = bitxor(c, 4294967294);")),
    # records: SHA-256 (RecordsTest)
    ("records", "sha256: padding starts with 0x80", SHA,
     swap("    m = [m, 128, zeros(1, pad), len];", "    m = [m, 1, zeros(1, pad), len];")),
    ("records", "sha256: zero padding to 56 mod 64", SHA,
     swap("    pad = mod(55 - n, 64);", "    pad = mod(55 - n, 64) + 64 * (mod(n, 64) == 55);")),
    ("records", "sha256: message schedule sigma0", SHA,
     swap("s0 = bitxor(bitxor(rotr(x, 7), rotr(x, 18)), floor(x / 8));",
          "s0 = bitxor(bitxor(rotr(x, 7), rotr(x, 18)), floor(x / 4));")),
    ("records", "sha256: rotation", SHA, swap("    y = (x - lo) / p + lo * 2^(32 - n);", "    y = (x - lo) / p + lo * 2^(31 - n);")),
    ("records", "sha256: round constant", SHA, swap("'c67178f2'", "'c67178f3'")),
    ("records", "sha256: big-endian length", SHA, swap("    for k = 8:-1:1", "    for k = 1:8")),
    # npy: .npy files written by NumPy (NpyTest)
    ("npy", "v2/v3 header length is 4 bytes", NPY,
     swap("header_length = fread(fid, 1, 'uint32');", "header_length = fread(fid, 1, 'uint16');")),
    ("npy", "big-endian refused", NPY, drop("Big-endian arrays")),
    ("npy", "float32 read as single", NPY, swap("'f4', 'single'", "'f4', 'double'")),
    ("npy", "truncated numeric data", NPY,
     swap("    if numel(values) ~= count\n", "    if false\n")),
    ("npy", "truncated string data", NPY,
     swap("        if numel(units) ~= width * count\n", "        if false\n")),
    ("npy", "bool becomes logical", NPY, swap("values = values ~= 0;", "values = values;")),
    # trace: .npz reader and DelayTrace.delay (TraceTest)
    ("trace", "delay outside the segment", TRACE, drop("Simulation exceeds imported trace segment")),
    ("trace", "searchsorted side='right'", TRACE,
     swap("index = max(1, sum(ts <= time));", "index = max(1, sum(ts < time));")),
    ("trace", "NaN time takes the last delay", TRACE,
     swap("            if isnan(time)\n", "            if false\n")),
    ("trace", "npy strips trailing NULs", NPY, swap("last = find(cp ~= 0, 1, 'last');", "last = numel(cp);")),
    ("trace", "npy C order", NPY,
     swap("value = permute(reshape(values, fliplr(dims)), numel(dims):-1:1);", "value = reshape(values, dims);")),
    ("trace", "npy refuses object arrays", NPY, drop("Object arrays cannot be loaded")),
    # transport: physical profile (TransportTest)
    ("transport", "round robin after last agent", TRANSPORT_M,
     swap("later = eligible(eligible > L.last_agent);", "later = eligible(eligible >= L.last_agent);")),
    ("transport", "partly served message resumes at the front", TRANSPORT_M,
     swap("obj.push_front(k, value{2}.message.agent, {value{2}, value{3}});",
          "obj.push_back(k, value{2}.message.agent, {value{2}, value{3}});")),
    ("transport", "chunks of packet_payload_bytes", TRANSPORT_M,
     swap("served = min(q.remaining_bytes, c.packet_payload_bytes);", "served = q.remaining_bytes;")),
    ("transport", "overhead per started 1500-byte packet", TRANSPORT_M,
     swap("wire = served + ceil(served / 1500) * c.packet_overhead_bytes;",
          "wire = served + floor(served / 1500) * c.packet_overhead_bytes;")),
    ("transport", "no overhead without fragmentation", TRANSPORT_M,
     swap("                wire = served;\n", "                wire = served + ceil(served / 1500) * c.packet_overhead_bytes;\n")),
    ("transport", "propagation on satellite links only", TRANSPORT_M,
     swap("            else\n                propagation = 0.0;", "            else\n                propagation = c.one_way_propagation_seconds;")),
    ("transport", "transmit logged at first start", TRANSPORT_M,
     swap("                    time = q.first_start;", "                    time = obj.now;")),
    ("transport", "log_service_chunks", TRANSPORT_M,
     swap("if c.log_service_chunks || done", "if done")),
    ("transport", "queue time accumulates over chunks", TRANSPORT_M,
     swap("q.queue_seconds = q.queue_seconds + (obj.now - q.ready_at);", "q.queue_seconds = obj.now - q.ready_at;")),
    ("transport", "handover time logged", TRANSPORT_M,
     swap("interrupted = finish - obj.now - duration;", "interrupted = 0;")),
    ("transport", "no pause before the first window", TRANSPORT_M,
     swap("if index > 0 && time < window + pause", "if time < window + pause")),
    ("transport", "transmission fits the window exactly", TRANSPORT_M,
     swap("if remaining <= available", "if remaining < available")),
    ("transport", "residue of 1e-14 s counts as done", TRANSPORT_M,
     swap("while remaining > 1e-14", "while remaining > 0")),
    ("transport", "pause after each crossed window", TRANSPORT_M,
     # Half the pause, not none: with no pause at all the cursor can sit on a
     # window boundary forever (the zero-interruption hang described in
     # Transport.finish_transmission), which would be a TIMEOUT, not a test.
     swap("                time = next_window + pause;\n", "                time = next_window + pause / 2;\n")),
    ("transport", "handover_end after the interruption", TRANSPORT_M,
     swap("obj.event(at + c.handover_interruption_seconds, 'handover_end'", "obj.event(at, 'handover_end'")),
    ("transport", "traced links unaffected by handovers", TRANSPORT_M,
     swap("affects = names(~cellfun(@(n) isfield(obj.traces, n), names));", "affects = names;")),
    ("transport", "trace replay uses the backhaul offset", TRANSPORT_M,
     swap("d = obj.traces.(name).delay(at + c.backhaul_time_offset_seconds);", "d = obj.traces.(name).delay(at);")),
    ("transport", "traced hop replaces link service", TRANSPORT_M,
     swap("elseif isfield(obj.traces, name)", "elseif false")),
    ("transport", "traces replayed only in physical", TRANSPORT_M,
     swap("                elseif ~physical\n", "                elseif false\n")),
    ("transport", "no model snapshots over traces", TRANSPORT_M, drop("UDP packet-delay traces do not calibrate")),
    ("transport", "trace direction", TRANSPORT_M, drop("Trace direction mismatch")),
    ("transport", "envelope timestamp is a float", TRANSPORT_M,
     swap("'timestamp', double(generated)", "'timestamp', int64(generated)")),
    ("transport", "delivered bytes include the envelope", TRANSPORT_M,
     swap("obj.counters.bytes_delivered = obj.counters.bytes_delivered + packet.size_bytes + header;",
          "obj.counters.bytes_delivered = obj.counters.bytes_delivered + packet.size_bytes;")),
    ("transport", "hop bytes include packet overhead", TRANSPORT_M,
     swap("obj.counters.hop_bytes_transmitted = obj.counters.hop_bytes_transmitted + wire;",
          "obj.counters.hop_bytes_transmitted = obj.counters.hop_bytes_transmitted + served;")),
    ("transport", "occupancy: reservation buffer is future hop 0", TRANSPORT_M,
     swap("if value{2} == 0 && at > obj.now", "if value{2} == 0")),
    ("transport", "occupancy: queued remaining bytes", TRANSPORT_M,
     swap("                            total = total + q.remaining_bytes;",
          "                            total = total + q.message.size_bytes + queues{j}{e}{2};")),
    ("transport", "occupancy: transmitting remainder", TRANSPORT_M,
     swap("transmitting = transmitting + value{2}.remaining_bytes;", "transmitting = transmitting + 0;")),
    ("transport", "advance ends at now = until", TRANSPORT_M,
     swap("obj.now = double(until_time);", "obj.now = obj.now;")),
    ("transport", "handover windows overlap the start", TRANSPORT_M,
     swap("if i * interval + pause >= start", "if true")),
    ("transport", "handover windows from k = 1", TRANSPORT_M,
     swap("for i = max(1, floor(start / interval)):floor(finish / interval)",
          "for i = max(0, floor(start / interval)):floor(finish / interval)")),
    ("env", "odd agent start/goal order", POP,
     swap("        starts(end + 1, :) = cells(end, :);\n        goals(end + 1, :) = cells(end - 1, :);",
          "        starts(end + 1, :) = cells(end - 1, :);\n        goals(end + 1, :) = cells(end, :);")),
    ("env", "pair goals swapped", POP,
     swap("goals = [goals; second; first];", "goals = [goals; first; second];")),
]

# Equivalent mutants are left out: a separate "dotted key through a value"
# prefix check was removed from toml_decode because the final lookup in
# check_assign already rejects it (the sweep showed it could not be killed).
# In Transport.m, two Python conditions cannot change any result without an
# orbital timeline (M5) and have no mutant: the link eligibility test
# ready_at <= now + 1e-12 (a queued message is always ready when it is
# queued) and max(latest_arrival, finish + propagation) (propagation is
# constant, so the last chunk is always the latest). The no-progress guard
# in finish_transmission has no mutant either: without it the test does
# what Python does, loop forever, which the sweep could only report as
# TIMEOUT; TransportTest checks the guard's error on the two cases.
# In npy_bytes, the 21 - len(repr(shape[0])) spaces of room for growing
# the first axis have no mutant: spaces padding the header to a multiple of
# 64 bytes follow them, and the header text before padding stays under 100
# bytes (padded to 128) for any shape and string width import_trace can
# write, so one growth space more or less gives the same bytes.

TESTS = {"config": ["Config"], "toml": ["Toml"], "env": ["Rng"], "encode": ["Encode"],
         "trace": ["Trace"], "npy": ["Npy"], "transport": ["Transport"],
         "mission": ["Information"],
         # Two physical rollouts (stale fields, short cap): about a minute per mutant.
         "rollout": ["EnvironmentParityTest/testPhysicalStaleAllUav",
                     "EnvironmentParityTest/testPhysicalTruncation"],
         "trace_import": ["ImportTrace"], "records": ["Records"]}


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


def run_tests(tree, patterns):
    """Run the test patterns (run_tests.m) in one Octave; return (verdict, summary).

    verdict is "pass" (every test passed), "assert" (at least one test
    FAILed on a verify/assert, even if other tests ERRORed), "error" (no
    assertion failed, but a test
    ERRORed with an unexpected exception or the run printed no summary) or
    "timeout".
    """
    calls = " ".join(f"ok = run_tests('{p}') && ok;" for p in patterns)
    cmd = [OCTAVE, "--no-gui", "--eval", f"cd matlab; ok = true; {calls} exit(~ok)"]
    try:
        res = subprocess.run(cmd, cwd=tree, capture_output=True, text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "timeout", f"no result after {TIMEOUT} s"
    out = res.stdout + res.stderr
    found = re.findall(r"(\d+) passed, (\d+) failed", out)
    fails = len(re.findall(r"^  FAIL ", out, re.M))
    errors = len(re.findall(r"^  ERROR ", out, re.M))
    if len(found) != len(patterns):
        return "error", f"{len(found)} of {len(patterns)} summaries (run errored)"
    passed = sum(int(a) for a, _ in found)
    failed = sum(int(b) for _, b in found)
    summary = f"{passed} passed, {failed} failed ({fails} FAIL, {errors} ERROR)"
    if res.returncode == 0 and failed == 0:
        return "pass", summary
    return ("assert" if fails else "error"), summary


VERDICT = {"pass": "SURVIVED", "assert": "killed", "error": "ERRORED", "timeout": "TIMEOUT"}


def main(argv):
    groups = [a for a in argv if not a.startswith("-")] or list(TESTS)
    chosen = [m for m in MUTANTS if m[0] in groups]
    if "--list" in argv:
        for g, name, path, _ in chosen:
            print(f"{g:12} {name:48} {path}")
        return 0
    lines = []
    ok = True
    counts = {g: {v: 0 for v in VERDICT.values()} for g in groups}
    with tempfile.TemporaryDirectory(prefix="mutation_sweep_") as tmp:
        tree = Path(tmp) / "repo"
        copy_tree(tree)
        for group in groups:
            status, summary = run_tests(tree, TESTS[group])
            lines.append(f"baseline {group:12} {'+'.join(TESTS[group])}: {summary}")
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
            verdict = VERDICT[status]
            counts[group][verdict] += 1
            # Only assertion kills count as covered: a crash or a hang shows
            # the mutant broke something, not that a test checks the rule.
            ok = ok and verdict == "killed"
            lines.append(f"{verdict:8} {group:12} {name:48} {summary} ({time.time() - t0:.0f} s)")
            print(lines[-1], flush=True)
    for group in groups:
        c = counts[group]
        total = sum(c.values())
        lines.append(f"{group}: {c['killed']}/{total} killed by assertions, {c['ERRORED']} errored, "
                     f"{c['TIMEOUT']} timed out, {c['SURVIVED']} survived")
        print(lines[-1])
    out = ROOT / "matlab" / "output" / "mutation_sweep.txt"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"written {out.relative_to(ROOT)}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
