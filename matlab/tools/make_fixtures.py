"""Generate golden parity fixtures for the MATLAB port from the Python code.

Run from the repository root with the Python package's dependencies installed
(numpy, simpy; torch is not needed for the M1 fixtures):

    python matlab/tools/make_fixtures.py            # all fixture groups
    python matlab/tools/make_fixtures.py env maps   # selected groups

Fixtures are JSON in matlab/tests/fixtures/ (large groups gzip-compressed as
.json.gz). JSON has no Infinity, so float
infinities are written as the strings "inf"/"-inf" (see
panama_uav.util.fixture_number on the MATLAB side). Randomness drawn by NumPy
(start/goal shuffles, reservation windows) is recorded so MATLAB can inject the
same draws; see matlab/PORT_PLAN.md section 5.

To add a fixture group, write a function ``group_<name>()`` that returns a
JSON-serializable dict and add it to GROUPS.
"""

from __future__ import annotations

import gzip
import json
import math
import pickle
import platform
import sys
import tomllib
from dataclasses import replace
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src"))

from panama_uav.config import ExperimentMode, load_config  # noqa: E402
from panama_uav.environment import ExperimentEnvironment, astar_path  # noqa: E402
from panama_uav.event_calendar import EventCalendar  # noqa: E402
from panama_uav.information import Guidance  # noqa: E402
from panama_uav.scenarios import load_map, load_scenario  # noqa: E402
from panama_uav.transport import Transport  # noqa: E402
from panama_uav.uav import AirToGroundModel, UAVController  # noqa: E402

OUT = ROOT / "matlab" / "tests" / "fixtures"


def canonical(value):
    """Type-preserving text; must match +panama_uav/+util/canonical.m."""
    if isinstance(value, dict):
        return "{" + ",".join(f"{k}:{canonical(v)}" for k, v in value.items()) + "}"
    if isinstance(value, (list, tuple)):
        return "[" + ",".join(canonical(v) for v in value) + "]"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return f"i{value}"
    if isinstance(value, str):
        return f"s{len(value)}:{value}"
    if value is None:
        return "none"
    if isinstance(value, float):
        if math.isinf(value):
            return "finf" if value > 0 else "f-inf"
        if math.isnan(value):
            return "fnan"
        return "f" + format(value, ".17g")
    raise TypeError(type(value))


def clean(value):
    """Make a value JSON-safe: infinities become strings, tuples lists."""
    if isinstance(value, dict):
        return {str(k): clean(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [clean(v) for v in value]
    if isinstance(value, np.ndarray):
        return clean(value.tolist())
    if isinstance(value, (np.floating,)):
        value = float(value)
    if isinstance(value, (np.integer,)):
        return int(value)
    if isinstance(value, (np.bool_,)):
        return bool(value)
    if isinstance(value, float) and math.isinf(value):
        return "inf" if value > 0 else "-inf"
    if isinstance(value, float) and math.isnan(value):
        return "nan"
    return value


def base_config():
    return load_config(ROOT / "configs" / "base.toml")


def with_comm(config, **changes):
    return replace(config, communication=replace(config.communication, **changes))


# ---------------------------------------------------------------- groups


# Small texts for decoder parity with tomllib: number grammar, duplicate
# keys and tables, and end-of-input positions. Each is recorded with
# tomllib's result or its error location ("line N" or "end of document").
TOML_TEXTS = [
    # numbers tomllib rejects
    "a = -", "a = +", "a = 1.", "a = 1__0", "a = 1_", "a = _1", "a = 01", "a = 00",
    "a = 0_1", "a = .5", "a = 1.e5", "a = 1._0", "a = 1.0_", "a = 1e", "a = 1e_5",
    "a = -0x1", "a = 0x", "a = 0xg", "a = 0X1", "a = inf_",
    # numbers tomllib accepts
    "a = 1_000", "a = 1e5", "a = -2E-3", "a = +inf", "a = -nan", "a = 0.0", "a = -0",
    "a = +7", "a = 0o17", "a = 0b101", "a = 0xDEAD_beef", "a = 1_0.0_1e1_0", "a = 1.5E-3",
    # duplicate keys and tables
    "a = 1\na = 2", "a = 1\na = 2\n", "[t]\nx = 1\nx = 2", "a.b = 1\na.b = 2",
    "a = 1\na.b = 2", "a = {b = 1, b = 2}", "a = {b = 1}\na.c = 2",
    "[t]\nx = 1\n[t]\ny = 2", "[t]\n[t.u]\n[t]", "a = 1\n[a]", "a.b = 1\n[a]",
    "[x]\na.b = 1\n[x.a]", "[a.b]\nc = 1\n[a]\nb.d = 2", "[t]\nu = {}\n[t.u]",
    "a = [1]\n[[a]]", "[[t]]\n[t]", "[t]\n[[t]]", "[[x.t]]\n[x]\nt.y = 1",
    "[[x.t]]\n[x]\nt = 1", "a = 1\na.b.c = 2", "a = {b = {c = 1}}\na.b.d = 2",
    # valid re-openings
    "[a.b]\n[a]", "[a]\n[a.b]", "a.b = 1\na.c = 2", "[[t]]\nx = 1\n[[t]]\nx = 2",
    "[[t]]\n[t.u]\nx = 1\n[[t]]\n[t.u]\nx = 2", "[a.b]\nc = 1\n[a]\nd = 2",
    # dotted keys inside inline tables (namespace tracking as at top level)
    "a = {b.c = 1, b.c = 2}", "a = {b = {c = 1}, b.d = 2}", "a = {b = 1, b.c = 2}",
    'b = {c = {}, c.c = "s"}', "a = {b.c = 1, b.d = 2}", "a = [{b = 1, b = 2}]",
    "a = {a = {b.a = 1}, a.b.a = 2}\n[c.b.c]\n[a]", "a = {b = {c = 1}}\n[a.b]",
    "a = {b.c = 1}\na.b.d = 2", "a = {b = {c = {d = 1}}, e.f.g = 2}",
    # line endings: CRLF is fine, a bare CR is not
    "a = 1\r", "a = 1\r\n", "a = 1\rb = 2", "# c\r", "# c\r\na = 1", "a = 1 # c\r\n",
    "\r\na = 1", "a = 1\r\r\n",
    # int64 bounds (in range; out-of-range values are a documented divergence)
    "a = 9223372036854775807", "a = -9223372036854775808", "a = 0x7FFFFFFFFFFFFFFF",
    "a = 0o777777777777777777777", "a = -0",
    # non-ASCII text (Octave keeps UTF-8 bytes; canonical counts code points)
    'k = "é"', 'k = "naïve ünïcödé"', "k = 'π≈3.14'", 'k = "x" # é',
    # end of input with and without a final newline
    "[training", "[training\n", "k = [1,\n2", "k = [1,\n2\n", "a = \"x", "a = {b = 1",
]


# Byte-level texts (control characters and UTF-8 validity), stored as hex.
# Python decodes the bytes as UTF-8 first (as tomllib.load does), then parses.
TOML_BYTES = [
    b'a = "x\x01"', b'a = "x\x7f"', b'a = "x\x00"', b'a = "x\ty"', b"a = 'x\x1f'",
    b"a = 'x\x7f'", b'a = "x\ry"', b'a = "x\r\n"', b'"k\x01" = 1', b"'k\x02' = 1",
    b'"k\rk" = 1', b"# c\x01\na = 1", b"# c\x7f", b"# c\t\na = 1", b"a = 1 # \x02",
    b"# \x00", b'a = "\x1b[0m"', b'a = "tab\there"',
    b'a = "\xff"', b'a = "\xc3', b'a = "\xc3"', b'a = "\xc0\xaf"', b'a = "\xed\xa0\x80"',
    b'a = "\xe0\x80\x80"', b'a = "\xf0\x80\x80\x80"', b'a = "\xf4\x90\x80\x80"', b'a = "\xf5"',
    b"# \xe2\x82", b'a = "\xe2\x82x"', b'a = "\xf0\x9f\x98', b'a = "\x80"',
    b'a = "\xef\xbf\xbf"', b'a = "\xf0\x9f\x98\x80"', b'a = "\xed\x9f\xbf"',
    b'a = "\xf4\x8f\xbf\xbf"', b"# \xc3\xa9\na = 1", b"k = '\xc3\xa9\xe2\x82\xac'",
]


def toml_bytes_case(raw):
    case = {"hex": raw.hex()}
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        return {**case, "accepted": False, "utf8": str(exc)}
    try:
        return {**case, "accepted": True, "canonical": canonical(tomllib.loads(text))}
    except tomllib.TOMLDecodeError as exc:
        return {**case, "accepted": False, "location": toml_location(exc), "message": str(exc)}


def toml_location(exc):
    text = str(exc)
    if "(at end of document)" in text:
        return "end of document"
    return "line " + text.rsplit("(at line ", 1)[1].split(",", 1)[0]


def group_toml():
    cases = []
    for path in sorted((ROOT / "configs").glob("*.toml")):
        raw = tomllib.loads(path.read_text(encoding="utf-8"))
        cases.append({"file": f"configs/{path.name}", "canonical": canonical(raw)})
    texts = []
    for text in TOML_TEXTS:
        try:
            texts.append({"text": text, "accepted": True, "canonical": canonical(tomllib.loads(text))})
        except tomllib.TOMLDecodeError as exc:
            texts.append({"text": text, "accepted": False, "location": toml_location(exc),
                          "message": str(exc)})
    return {"cases": cases, "texts": texts, "bytes": [toml_bytes_case(b) for b in TOML_BYTES]}


def group_config():
    c = base_config()
    d = c.to_dict()
    d.pop("project_root")
    rejected = []
    for name in sorted((ROOT / "configs").glob("*.toml")):
        try:
            loaded = load_config(name).to_dict()
            loaded.pop("project_root")
            rejected.append({"file": f"configs/{name.name}", "accepted": True,
                             "config": clean(loaded)})
        except Exception as exc:  # noqa: BLE001
            rejected.append({"file": f"configs/{name.name}", "accepted": False,
                             "error": type(exc).__name__})
    return {"base": clean(d), "smoke_training": clean(c.profile("smoke").to_dict()["training"]),
            "vector_length": c.vector_length, "files": rejected,
            "synthetic": synthetic_configs()}


# Small TOML texts that exercise load_config's accept/reject rules. The
# repository's configs/ only holds accepted files, so rejection parity is
# pinned here. Each text is written to <tmp>/configs/<name>.toml (load_config
# takes the project root from the file's grandparent directory).
SYNTHETIC_CONFIGS = {
    "empty": "",
    "legacy_extends": 'extends = "base.toml"\n',
    "legacy_section": "[static_radio]\nsnr_db = 10.0\n",
    "validation_episodes_100": "[training]\nvalidation_episodes = 100\n",
    # A key TrainingConfig does not have: Python's dataclass constructor
    # raises TypeError (its message names the Python class, so only the
    # rejection is compared); MATLAB raises panama_uav:config.
    "unknown_training_key": "[training]\nbogus = 1\n",
    "bad_profile": '[communication]\nprofile = "bogus"\n',
    "three_windows": "[communication]\nwindows_min = 3\nwindows_max = 3\n",
    # One case per remaining load_config / TransportConfig rule, so each
    # rule is exercised with Python's message (matlab/tools/mutation_sweep.py
    # disables each rule in turn and checks that a test fails).
    "reward_changed": "[reward]\ngoal = 1.0\n",
    "map_changed": "[map]\nfov_radius = 5\n",
    "budget_zero": "[training]\nbudget_seconds = 0.0\n",
    "budget_over_24h": "[training]\nbudget_seconds = 86401.0\n",
    "bad_mission_route": '[communication]\nmission_route = "satellite"\n',
    "bad_stale_information": '[communication]\nstale_information = ["task", "weather"]\n',
    "bad_simulated_time": "[communication]\nseconds_per_step = 0.0\n",
    "negative_backhaul_offset": "[communication]\nbackhaul_time_offset_seconds = -1.0\n",
    "negative_packet_size": "[communication]\npacket_payload_bytes = -1\n",
    "bad_scheduling_frame": "[communication]\nscheduler_guard_fraction = 1.0\n",
    "orbital_replay_without_timeline": "[communication]\norbital_replay = true\n",
    "bad_model_distribution": '[communication]\nmodel_distribution = "broadcast"\n',
    "timeline_and_trace": ('[communication]\nleo_timeline = "data/leo/timeline.npz"\n'
                           'uplink_trace = "traces/up.npz"\n'),
    "zero_reservation": "[communication]\nreservation_steps = 0\n",
    "zero_capacity": "[communication]\nsatellite_uplink_mbps = 0.0\n",
    "bad_physical_delays": "[communication]\nhandover_interval_seconds = 0.0\n",
    "wrong_ladder": ('[[curriculum.stages]]\nname = "a"\nnum_agents = 3\n'
                     'map_path = "maps/random-32-32-10.map"\nmax_episode_steps = 250\n'
                     "min_episodes = 500\n"),
}


def synthetic_configs():
    import tempfile
    out = []
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / "configs").mkdir()
        for name, text in SYNTHETIC_CONFIGS.items():
            path = Path(tmp) / "configs" / f"{name}.toml"
            path.write_text(text, encoding="utf-8")
            try:
                loaded = load_config(path).to_dict()
                loaded.pop("project_root")
                out.append({"name": name, "text": text, "accepted": True, "config": clean(loaded)})
            except Exception as exc:  # noqa: BLE001
                out.append({"name": name, "text": text, "accepted": False,
                            "error": type(exc).__name__, "message": str(exc)})
    return out


def group_maps():
    maps = []
    for path in sorted((ROOT / "maps").glob("*.map")):
        grid = load_map(path)
        maps.append({"file": f"maps/{path.name}", "shape": list(grid.shape),
                     "obstacles": np.flatnonzero(grid.ravel(order="C")).tolist()})
    scen_dir = ROOT / "scens" / "scen-random-32-32-10"
    scens = []
    for path in sorted(scen_dir.glob("*.scen"))[:3]:
        s = load_scenario(path, ROOT / "maps", 8)
        scens.append({"file": str(path.relative_to(ROOT)).replace("\\", "/"),
                      "map": s.map_path.name, "starts": s.starts, "goals": s.goals})
    return {"maps": maps, "scenarios": clean(scens)}


def group_astar():
    grid = load_map(ROOT / "maps" / "random-32-32-10.map")
    rng = np.random.default_rng(7)
    free = np.argwhere(grid == 0)
    cases = []
    for _ in range(60):
        a, b = free[rng.integers(len(free))], free[rng.integers(len(free))]
        start, goal = (int(a[0]), int(a[1])), (int(b[0]), int(b[1]))
        cases.append({"start": start, "goal": goal, "path": astar_path(grid, start, goal)})
    cases.append({"start": (0, 0), "goal": (0, 0), "path": astar_path(grid, (0, 0), (0, 0))})
    # Unreachable: goal on an obstacle.
    blocked = np.argwhere(grid == 1)[0]
    cases.append({"start": tuple(int(v) for v in free[0]), "goal": tuple(int(v) for v in blocked),
                  "path": astar_path(grid, tuple(int(v) for v in free[0]), tuple(int(v) for v in blocked))})
    # Hand-made grids where up/down and left/right expansions tie, so the
    # neighbour order (up, down, left, right) is pinned by MapsTest itself.
    small = []
    g1 = np.zeros((3, 5), dtype=np.uint8)
    g1[1, 2] = 1                      # wall in the middle row: detour above or below
    g2 = g1.T.copy()                  # wall in the middle column: detour left or right
    g3 = np.zeros((5, 5), dtype=np.uint8)
    g3[2, 1:4] = 1                    # longer symmetric detours
    for grid, start, goal in ((g1, (1, 0), (1, 4)), (g1, (1, 4), (1, 0)),
                              (g2, (0, 1), (4, 1)), (g2, (4, 1), (0, 1)),
                              (g3, (1, 2), (3, 2)), (g3, (3, 2), (1, 2)),
                              (g3, (2, 0), (2, 4))):
        small.append({"grid": grid.tolist(), "start": start, "goal": goal,
                      "path": astar_path(grid, start, goal)})
    return {"map": "maps/random-32-32-10.map", "cases": clean(cases), "tie_cases": clean(small)}


def group_uav():
    c = base_config()
    model = AirToGroundModel(c.uav)
    controller = UAVController((32, 32), 1.0, c.uav)
    rng = np.random.default_rng(3)
    steps = []
    for _ in range(25):
        points = rng.integers(0, 32, size=(int(rng.integers(1, 9)), 2))
        xy = controller.positions_to_xy_m([tuple(map(int, p)) for p in points])
        d = controller.update(xy)
        q = controller.snapshot().quality_db
        steps.append({"positions": points.tolist(), "position": controller.position.tolist(),
                      # float32 snapshot at fixed cells, and its float64 sum
                      "snapshot_cells": [float(q[r, c]) for r, c in ((0, 0), (5, 17), (16, 16), (31, 2), (31, 31))],
                      "snapshot_sum": float(q.astype(np.float64).sum()),
                      "target": d.target_position.tolist(), "moved": d.distance_moved,
                      "oracle": d.oracle_served, "actual": d.actual_served,
                      "tracking": d.tracking_error_m})
    snap = controller.snapshot()
    horiz = [0.0, 1.0, 5.0, 12.5, 40.0, 100.0]
    return {"alpha_opt": model.alpha_opt, "max_radius": model.maximum_radius_m,
            "optimal_height": model.optimal_height_m,
            "horizontal": horiz, "path_loss_h30": model.path_loss_db(30.0, np.array(horiz)).tolist(),
            "snr_h30": model.effective_snr_db(30.0, np.array(horiz)).tolist(),
            "steps": steps, "snapshot_quality": snap.quality_db.astype(float).tolist(),
            "snapshot_normalized": snap.normalized.astype(float).tolist()}


def hexfloat(x):
    """Exact IEEE-754 bits as 16 hex digits (Octave's jsondecode is not correctly rounded)."""
    import struct
    return struct.pack(">d", float(x)).hex()


def group_calendar():
    """Replayable op list: schedule(at, value) and pop(), with ties and float offsets.

    Times are stored as exact hex bits (``*_hex``) as well as decimals."""
    cal = EventCalendar()
    rng = np.random.default_rng(11)
    ops = []
    for k in range(60):
        now = cal.environment.now
        if k % 4 == 3 and cal.records():
            at, token, kind, value = cal.pop()
            peek = cal.peek() if cal.records() else math.inf
            ops.append({"op": "pop", "at": at, "at_hex": hexfloat(at), "token": token,
                        "value": value, "peek_hex": hexfloat(peek)})
            continue
        # Mix exact ties (multiples of 0.25) with irrational offsets (0.1 steps).
        at = now + (float(rng.integers(0, 8)) * 0.25 if k % 2 else float(rng.integers(0, 30)) * 0.1)
        cal.schedule(at, "e", k)
        ops.append({"op": "schedule", "at": at, "at_hex": hexfloat(at), "value": k})
    while cal.records():
        at, token, kind, value = cal.pop()
        peek = cal.peek() if cal.records() else math.inf
        ops.append({"op": "pop", "at": at, "at_hex": hexfloat(at), "token": token,
                    "value": value, "peek_hex": hexfloat(peek)})
    return {"ops": ops}


def _env_run(config, agents, seed, steps, policy_seed, cap=250):
    env = ExperimentEnvironment(config, ExperimentMode.UAV, "maps/random-32-32-10.map",
                                agents, cap, seed)
    obs, info0 = env.reset()
    reset_obs = {"spatial_ones": [np.flatnonzero(obs[a.id]["spatial"].ravel()).tolist()
                                  for a in env.agents],
                 "vector": [obs[a.id]["vector"].astype(float).tolist() for a in env.agents]}
    starts = [a.position for a in env.agents]
    goals = [a.goal for a in env.agents]
    windows = {a: w for a, w in env.communication.transport.windows.items()}
    rng = np.random.default_rng(policy_seed)
    frames = []
    for _ in range(steps):
        actions = {a.id: int(rng.integers(0, 5)) for a in env.agents}
        # Bias toward the A* route so goals are actually reached.
        for a in env.agents:
            if rng.random() < 0.7 and a.path and len(a.path) > 1:
                d = (a.path[1][0] - a.position[0], a.path[1][1] - a.position[1])
                actions[a.id] = {(-1, 0): 0, (1, 0): 1, (0, -1): 2, (0, 1): 3}[d]
        r = env.step(actions)
        i = r.info
        frames.append({
            "actions": [actions[a.id] for a in env.agents],
            "positions": i["agent_positions"],
            "rewards": [r.rewards[a.id] for a in env.agents],
            "terminated": r.terminated, "truncated": r.truncated,
            "collisions_obstacle": i.get("collisions_obstacle_step", 0.0),
            "collisions_agent": i["collisions_agent_agent_step"],
            "path_conflict": i.get("path_conflict_penalty_step", 0.0),
            "targets": i.get("targets_reached_step", 0.0),
            "at_goal": i["agents_at_goal_step"],
            "uav": i["uav_position"], "uav_moved": i["uav_distance_moved_step"],
            # Spatial observations are 0/1; store C-order flat indices of the ones.
            "spatial_ones": [np.flatnonzero(r.observations[a.id]["spatial"].ravel()).tolist()
                             for a in env.agents],
            "vector": [r.observations[a.id]["vector"].astype(float).tolist() for a in env.agents],
            "ages": [[i["information_age"][a.id][k] for k in ("task", "intentions", "priorities")]
                     for a in env.agents],
            "guidance": [i["cached_guidance"][a.id] for a in env.agents],
            "report_age": [i["uav_reports"][a.id]["age_seconds"] for a in env.agents],
            "priorities": [a.priority for a in env.agents],
        })
        if r.terminated or r.truncated:
            break
    log = [e for e in env.communication.transport.log if e["event"] in
           ("scheduled_reservation", "reservation_exposure", "buffered", "delivered")]
    log = [{k: e[k] for k in ("event", "time", "agent", "id", "kind", "release", "ready_at",
                               "source_time", "version") if k in e} for e in log]
    return {"agents": agents, "seed": seed, "cap": cap, "reset_observations": reset_obs,
            "starts": starts, "goals": goals,
            "windows": [windows.get(a, []) for a in range(agents)],
            "info0": info0, "frames": frames, "log": log,
            "counters": {"messages_generated": env.communication.transport.counters["messages_generated"],
                         "messages_delivered": env.communication.transport.counters["messages_delivered"],
                         "exposed_messages": env.communication.transport.counters["exposed_messages"]}}


ENV_CASES = [
    # name, communication overrides, agents, seed, steps
    ("fresh_a4", {}, 4, 123, 60),
    ("fresh_a8", {}, 8, 5, 80),
    ("stale_all_uav_d5", {"stale_information": ("task", "intentions", "priorities"),
                          "delay_steps": 5.0}, 4, 21, 80),
    ("stale_all_cloud_d10", {"stale_information": ("task", "intentions", "priorities"),
                             "mission_route": "cloud", "delay_steps": 10.0}, 6, 9, 80),
    ("stale_task_d20", {"stale_information": ("task",), "delay_steps": 20.0}, 4, 33, 80),
    ("stale_prio_int_d2", {"stale_information": ("intentions", "priorities"),
                           "delay_steps": 2.0, "windows_min": 2}, 6, 44, 80),
    ("perfect_stale", {"profile": "perfect", "stale_information": ("task",)}, 2, 7, 60),
    ("no_contention", {"stale_information": ("task", "intentions"), "contention_enabled": False,
                       "edge_processing_seconds": 0.3}, 4, 2, 60),
    ("cloud_processing", {"stale_information": ("task", "intentions", "priorities"),
                          "mission_route": "cloud", "cloud_processing_seconds": 1.5,
                          "delay_steps": 1.0}, 4, 8, 60),
    # Short cap so the episode truncates (cap is the 6th element).
    ("truncated_cap12", {"stale_information": ("task",), "delay_steps": 5.0}, 6, 17, 12, 12),
]


def group_env():
    c = base_config()
    out = {}
    for name, changes, agents, seed, steps, *cap in ENV_CASES:
        cfg = with_comm(c, **changes) if changes else c
        case = _env_run(cfg, agents, seed, steps, policy_seed=seed + 1000, cap=cap[0] if cap else 250)
        case["communication"] = {k: (list(v) if isinstance(v, tuple) else v)
                                 for k, v in changes.items()}
        out[name] = clean(case)
    return out


class Xorshift128:
    """Reference for +panama_uav/+util/Xorshift128.m (MATLAB/Octave portable stream)."""

    M = 0xFFFFFFFF

    def __init__(self, seed):
        lo, hi = seed & self.M, (seed >> 32) & self.M
        self.s = [lo ^ 123456789, hi ^ 362436069, 521288629, 88675123]
        for _ in range(64):
            self.next_uint32()

    def next_uint32(self):
        s = self.s
        t = (s[0] ^ (s[0] << 11)) & self.M
        t ^= t >> 8
        w = s[3]
        r = (w ^ (w >> 19)) ^ t
        self.s = [s[1], s[2], s[3], r]
        return r

    def rand(self):
        a = self.next_uint32() >> 5
        b = self.next_uint32() >> 6
        return (a * 67108864 + b) / 9007199254740992.0

    def randint(self, n):
        return math.floor(self.rand() * n)

    def permutation(self, n):
        p = list(range(1, n + 1))
        for i in range(n, 1, -1):
            j = self.randint(i) + 1
            p[i - 1], p[j - 1] = p[j - 1], p[i - 1]
        return p

    def choice(self, n, k):
        p = list(range(1, n + 1))
        for i in range(1, k + 1):
            j = i + self.randint(n - i + 1)
            p[i - 1], p[j - 1] = p[j - 1], p[i - 1]
        return p[:k]


def group_rng():
    """Streams of the portable MATLAB generator, from the pure-Python reference."""
    out = []
    for seed in (0, 1, 42, 123, 2**32 + 7):
        g = Xorshift128(seed)
        out.append({"seed": seed, "uint32": [g.next_uint32() for _ in range(8)],
                    "rand_hex": [hexfloat(g.rand()) for _ in range(4)],
                    "permutation": g.permutation(10), "choice": g.choice(249, 2)})
    return {"streams": out}


def group_golden01():
    """Seeded starts/goals behind tests/fixtures/zero_delay_01.json (seed 123, 4 agents)."""
    env = ExperimentEnvironment(base_config(), ExperimentMode.UAV,
                                "maps/random-32-32-10.map", 4, 250, 123)
    env.reset()
    return clean({"starts": [a.position for a in env.agents],
                  "goals": [a.goal for a in env.agents],
                  "windows": [env.communication.transport.windows.get(a, []) for a in range(4)]})


def group_guidance():
    g = Guidance([(1, 1), (1, 2), (1, 3), (2, 3)], 3)
    seq = [g.consume(p) for p in [(1, 1), (1, 2), (2, 2), (2, 3)]]
    return clean({"sequence": seq})


def group_popping():
    """Python's start/goal pop order after its shuffle (environment.py
    _random_starts_and_goals), on a 6-free-cell grid. The shuffled cell list
    is recorded too, so MATLAB can replay the pops on the same order."""
    import copy
    cases = []
    for n in (2, 3, 4, 5):
        for seed in (1, 4, 9):
            env = ExperimentEnvironment(base_config(), ExperimentMode.UAV,
                                        "maps/random-32-32-10.map", n, 250, seed)
            grid = np.ones_like(env.grid)
            grid.flat[:6] = 0
            env.grid = grid
            twin = copy.deepcopy(env.rng)
            cells = [tuple(int(v) for v in c) for c in np.argwhere(grid == 0)]
            twin.shuffle(cells)
            starts, goals = env._random_starts_and_goals()
            cases.append({"agents": n, "seed": seed, "shuffled": [list(c) for c in cells],
                          "starts": [list(c) for c in starts], "goals": [list(c) for c in goals]})
    return {"cases": cases}


# ------------------------------------------------- M1b: wire sizes, physical links, traces


def py_spec(value):
    """Typed description of a Python value for the MATLAB side (tests/py_value.m).

    Strings are UTF-8 hex (Octave's jsondecode cannot hold every code point),
    ints are decimal strings (JSON numbers lose precision past 2**53) and
    floats are IEEE hex bits."""
    if value is None:
        return {"t": "none"}
    if isinstance(value, bool):
        return {"t": "bool", "v": value}
    if isinstance(value, int):
        # 8 little-endian bytes: int64, or uint64 above 2**63 - 1.
        unsigned = value > 2**63 - 1
        raw = value.to_bytes(8, "little", signed=not unsigned)
        return {"t": "int", "v": str(value), "le": raw.hex(), "unsigned": unsigned}
    if isinstance(value, float):
        return {"t": "float", "hex": hexfloat(value)}
    if isinstance(value, str):
        if len(value) > 32 and len(set(value)) == 1:
            return Repeat("str", value[0], len(value)).spec()
        return {"t": "str", "hex": value.encode("utf-8").hex()}
    if isinstance(value, bytes):
        return {"t": "bytes", "n": len(value)}
    if isinstance(value, tuple):
        return {"t": "tuple", "items": [py_spec(v) for v in value]}
    if isinstance(value, list):
        return {"t": "list", "items": [py_spec(v) for v in value]}
    if isinstance(value, dict):
        return {"t": "dict", "keys": [py_spec(k) for k in value],
                "values": [py_spec(v) for v in value.values()]}
    raise TypeError(type(value))


class Repeat:
    """A long list, str or dict written compactly in the fixture (one item, a count)."""

    def __init__(self, kind, item, n):
        self.kind, self.item, self.n = kind, item, n

    def value(self):
        if self.kind == "list":
            return [self.item] * self.n
        if self.kind == "str":
            return self.item * self.n
        return {f"k{i}": self.item for i in range(self.n)}

    def spec(self):
        item = self.item if self.kind == "str" else py_spec(self.item)
        if self.kind == "str":
            item = self.item.encode("utf-8").hex()
        return {"t": "repeat_" + self.kind, "item": item, "n": self.n}


def _random_value(rng, depth=0):
    kinds = ["none", "bool", "int", "float", "str", "bytes"]
    if depth < 3:
        kinds += ["list", "tuple", "dict"] * 2
    kind = kinds[int(rng.integers(len(kinds)))]
    if kind == "none":
        return None
    if kind == "bool":
        return bool(rng.integers(2))
    if kind == "int":
        bits = int(rng.integers(0, 64))
        v = int(rng.integers(0, 2**bits)) if bits else 0
        return -v - int(rng.integers(2)) if rng.integers(2) else v
    if kind == "float":
        return float(rng.normal() * 10 ** int(rng.integers(-5, 6)))
    if kind == "str":
        alphabet = ["a", "Z", "_", " ", "\u00e9", "\u20ac", "\U0001f600", "\t"]
        n = int(rng.choice([0, 1, 2, 5, 9, 40, 255, 256], p=[.1, .2, .2, .2, .1, .1, .05, .05]))
        return "".join(alphabet[int(i)] for i in rng.integers(0, len(alphabet), n))
    if kind == "bytes":
        return bytes(int(rng.choice([0, 1, 255, 256, 1000, 65535, 65536, 70000])))
    n = int(rng.integers(0, 7))
    items = [_random_value(rng, depth + 1) for _ in range(n)]
    if kind == "list":
        return items
    if kind == "tuple":
        return tuple(items)
    return {f"k{i}_{int(rng.integers(100))}": v for i, v in enumerate(items)}


_SHARED = "shared " * 10    # one str object, used twice in group_encode


def group_encode():
    """len(transport.encode(value)) for plain value types (encode_size.m).

    The reference is transport.encode, not pickle.dumps: encode pickles with
    fast mode on, so there is no memo. pickle.dumps memoizes, and a value
    seen twice is written once and then fetched with BINGET, which is
    shorter. The last edge case below ([s, s] with one shared str) shows the
    difference."""
    from panama_uav.transport import encode
    edge = [None, True, False, 0, 1, 255, 256, 65535, 65536, -1, -255, 2**31 - 1, 2**31,
            -2**31, -2**31 - 1, 2**32, 2**39, -2**39, -2**39 - 1, -2**40, 2**47, -2**47,
            2**55, -2**55, 2**63 - 1, -2**63, 2**64 - 1, 0.0, -0.0, 1.5, math.inf, -math.inf,
            math.nan, "", "a", "\u00e9", "\U0001f600", "x" * 255, "x" * 256, "\u00e9" * 128,
            bytes(0), bytes(255), bytes(256), bytes(65535), bytes(65536), bytes(100000),
            (), (1,), (1, 2), (1, 2, 3), (1, 2, 3, 4), [], [1], [1, 2], {}, {"a": 1},
            {"a": 1, "b": 2}, {"agent": 0, "kind": "report", "timestamp": 0.0, "version": 0},
            {"agent": -1, "kind": "model_relay", "timestamp": 12.5, "version": 70000},
            ("x" * 65535,), ("x" * 65536,), [bytes(65000), bytes(600)],
            [bytes(65530), 1, 2], [bytes(65531), 1], [bytes(65532)],
            {"w": bytes(70000), "s": 3, "v": [1.0, 2.0]}, [_SHARED, _SHARED]]
    repeats = [Repeat("list", 1, 999), Repeat("list", 1, 1000), Repeat("list", 1, 1001),
               Repeat("list", 1, 2000), Repeat("list", 1, 2001), Repeat("list", "y" * 100, 700),
               Repeat("list", "y" * 300, 300), Repeat("list", (1, 2.0), 7000),
               Repeat("str", "\u20ac", 21845), Repeat("str", "\u20ac", 21846),
               Repeat("dict", 0, 999), Repeat("dict", 0, 1000), Repeat("dict", 0, 1001),
               Repeat("dict", 0, 2000), Repeat("dict", "z" * 80, 900)]
    rng = np.random.default_rng(2026)
    cases = [{"spec": py_spec(v), "size": len(encode(v))} for v in edge]
    cases += [{"spec": r.spec(), "size": len(encode(r.value()))} for r in repeats]
    cases += [{"spec": py_spec(v), "size": len(encode(v))}
              for v in (_random_value(rng) for _ in range(250))]
    return {"cases": cases}


def tagged(value):
    """Log/occupancy values with their Python type: floats become 'f:<hex bits>',
    strings 's:<text>', ints stay ints, lists and dicts recurse."""
    if isinstance(value, bool):
        return value
    if isinstance(value, float):
        return "f:" + hexfloat(value)
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return "s:" + value
    if isinstance(value, (list, tuple)):
        return [tagged(v) for v in value]
    if isinstance(value, dict):
        return {str(k): tagged(v) for k, v in value.items()}
    if value is None:
        return None
    raise TypeError(type(value))


TRACE_DIR = "matlab/tests/fixtures"


def _write_trace(name, direction, rows, unit, scale, start=None, end=None, origin=None):
    """Run Python's import_trace on a generated OWD text file, then store the
    .npz in the fixtures with metadata["source"] made repo-relative, so the
    file does not depend on where the repository is cloned."""
    import tempfile
    from panama_uav.transport import import_trace
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / f"{name}.txt"
        source.write_text("".join(f"{s} {t} {d}\n" for s, t, d in rows))
        out = Path(tmp) / f"{name}.npz"
        metadata = import_trace(source, out, direction, unit, start=start, end=end,
                                origin_seconds=origin)
        with np.load(out, allow_pickle=False) as data:
            arrays = {k: data[k] for k in data.files}
    metadata["source"] = f"{TRACE_DIR}/{name}.txt"
    arrays["metadata"] = json.dumps(metadata)
    # np.savez_compressed writes fixed ZIP timestamps (1980-01-01), so the
    # file is byte-identical on every run.
    np.savez_compressed(ROOT / TRACE_DIR / f"{name}.npz", **arrays)
    return arrays


def group_trace():
    """Delay traces: .npz files from import_trace and DelayTrace.delay queries."""
    from panama_uav.transport import DelayTrace
    rng = np.random.default_rng(77)
    # 80 ms samples (ns integers), sequence gaps included, one-way delays 20-60 ms.
    up_rows, seq = [], 0
    for k in range(600):
        seq += 1 + int(rng.random() < 0.05)
        up_rows.append((seq, 1_700_000_000_000_000_000 + 80_000_000 * k,
                        int(rng.integers(20_000_000, 60_000_000))))
    down_rows = [(k, 5_000 + 125_000 * k, int(rng.integers(15_000, 45_000))) for k in range(400)]
    _write_trace("trace_uplink", "uplink", up_rows, "ns", 1e-9,
                 start=1_700_000_000.5, end=1_700_000_046.0)
    _write_trace("trace_downlink", "downlink", down_rows, "us", 1e-6, origin=0.0)
    out = {}
    for name in ("trace_uplink", "trace_downlink"):
        trace = DelayTrace.load(ROOT / TRACE_DIR / f"{name}.npz")
        ts = trace.timestamps
        queries = [float(ts[0]), float(ts[-1]), float(ts[0]) - 1e-9, float(ts[-1]) + 1e-9,
                   math.nan, -math.inf, math.inf, float(ts[1]), float(ts[1]) - 1e-12,
                   float(ts[5]) + 1e-12]
        queries += [float(v) for v in rng.uniform(ts[0], ts[-1], 60)]
        results = []
        for q in queries:
            try:
                results.append({"time": hexfloat(q), "delay": hexfloat(trace.delay(q))})
            except ValueError as exc:
                results.append({"time": hexfloat(q), "error": str(exc)})
        with np.load(ROOT / TRACE_DIR / f"{name}.npz", allow_pickle=False) as data:
            # '<U' arrays are as wide as their longest string; shorter ones
            # are NUL-padded on disk and stripped by NumPy.
            sequence = [str(v) for v in data["sequence"]]
        out[name] = {"sequence": sequence, "timestamps": [hexfloat(v) for v in ts],
                     "delays": [hexfloat(v) for v in trace.delays],
                     "metadata": tagged(trace.metadata), "queries": results}
    return out


NPY_CLASSES = {"f8": "double", "f4": "single", "i8": "int64", "i4": "int32", "i2": "int16",
               "i1": "int8", "u8": "uint64", "u4": "uint32", "u2": "uint16", "u1": "uint8",
               "b1": "logical"}


def _npy_case(name, array, version=None, truncate=0, refused_by_port=None):
    """An .npy file written by NumPy (hex), and what np.load and read_npy give."""
    import io
    buf = io.BytesIO()
    np.lib.format.write_array(buf, array, version=version, allow_pickle=False)
    raw = buf.getvalue()
    if truncate:
        raw = raw[:-truncate]
    case = {"name": name, "hex": raw.hex()}
    try:
        loaded = np.lib.format.read_array(io.BytesIO(raw), allow_pickle=False)
    except ValueError as exc:
        return {**case, "error": str(exc)}
    if refused_by_port:
        # NumPy loads it; the port refuses it on purpose (read_npy.m docstring).
        return {**case, "port_error": refused_by_port, "numpy_loaded": True}
    if loaded.dtype.kind == "U":
        values = [str(v) for v in loaded.flatten(order="F")]
        # A 0-d string comes back as a char row, an array of strings as a cellstr.
        return {**case, "class": "char" if loaded.ndim == 0 else "cell",
                "size": _matlab_size(loaded.shape),
                "strings_hex": [v.encode("utf-8").hex() for v in values]}
    code = loaded.dtype.str[1:]
    as_le = loaded.astype(loaded.dtype.newbyteorder("<"))
    return {**case, "class": NPY_CLASSES[code], "size": _matlab_size(loaded.shape),
            "le": as_le.flatten(order="F").tobytes().hex()}


def _matlab_size(shape):
    if len(shape) == 0:
        return [1, 1]
    if len(shape) == 1:
        return [shape[0], 1]
    return list(shape)


def group_npy():
    """read_npy paths: header versions 1.0-3.0, dtypes, shapes, refusals, truncation."""
    f = np.array([0.1, -2.5, 1e300, -0.0, np.inf])
    cases = [
        _npy_case("v1 float64", f, version=(1, 0)),
        _npy_case("v2 float64", f, version=(2, 0)),
        _npy_case("v3 float64", f, version=(3, 0)),
        _npy_case("v2 strings", np.array(["a", "bc\u00e9"]), version=(2, 0)),
        _npy_case("float32", np.array([0.1, -3.25, 1e30, 16777217.0], dtype="<f4")),
        _npy_case("float32 0-d", np.array(np.float32(0.3))),
        _npy_case("bool", np.array([True, False, True, True])),
        _npy_case("bool 2-d", np.array([[True, False, False], [False, True, True]])),
        _npy_case("int64 extremes", np.array([-2**63, 2**63 - 1, 0, -1], dtype="<i8")),
        _npy_case("uint64 extremes", np.array([0, 2**64 - 1], dtype="<u8")),
        _npy_case("int8 2-d", np.array([[-128, 127]], dtype="<i1")),
        _npy_case("uint16", np.array([65535, 1], dtype="<u2")),
        _npy_case("float64 2-d C", np.arange(6.0).reshape(2, 3)),
        _npy_case("float64 2-d F", np.asfortranarray(np.arange(6.0).reshape(2, 3))),
        _npy_case("float64 3-d", np.arange(24.0).reshape(2, 3, 4)),
        _npy_case("0-d string", np.array("metadata \u20ac")),
        _npy_case("big-endian float64", np.array([1.5, 2.0], dtype=">f8"),
                  refused_by_port="Big-endian arrays (>f8) are not supported"),
        _npy_case("big-endian int32", np.array([7], dtype=">i4"),
                  refused_by_port="Big-endian arrays (>i4) are not supported"),
        _npy_case("truncated float64", f, truncate=8),
        _npy_case("truncated float32", np.array([1.0, 2.0, 3.0], dtype="<f4"), truncate=2),
        _npy_case("truncated bool", np.array([True, False, True]), truncate=1),
        _npy_case("truncated strings", np.array(["ab", "c"]), truncate=4),
        _npy_case("truncated v2", f, version=(2, 0), truncate=1),
    ]
    return {"cases": cases}


def _physical_config(**changes):
    from panama_uav.config import TransportConfig
    for key in ("uplink_trace", "downlink_trace"):
        if changes.get(key):
            changes[key] = str(ROOT / TRACE_DIR / changes[key])
    return TransportConfig(**changes)


def _run_transport(changes, ops):
    """Replay OPS on a Python Transport and record every observable result."""
    record = {"config": {k: (list(v) if isinstance(v, tuple) else v) for k, v in changes.items()},
              "ops": [], "results": []}
    try:
        t = Transport(_physical_config(**changes))
    except ValueError as exc:
        record["constructor_error"] = str(exc)
        return record
    for op in ops:
        record["ops"].append(op)
        try:
            if op["op"] == "send":
                payload = op["payload"]
                kwargs = {"route": tuple(op["route"]), "version": op.get("version", 0),
                          "delayed": op.get("delayed", True)}
                if "generated_at" in op:
                    kwargs["generated_at"] = op["generated_at"]
                if "wire_n" in op:
                    kwargs["wire"] = bytes(op["wire_n"])
                result = t.send(op["agent"], op["kind"], payload, **kwargs)
            elif op["op"] == "advance":
                result = [m.id for m in t.advance(op["until"])]
            elif op["op"] == "windows":
                t.windows = {int(a): [tuple(w) for w in ws] for a, ws in op["windows"].items()}
                result = None
            elif op["op"] == "occupancy":
                result = tagged(t.occupancy())
            elif op["op"] == "handover_windows":
                result = tagged(t.handover_windows(op["start"], op["end"]))
            else:
                raise KeyError(op["op"])
            record["results"].append({"value": result})
        except ValueError as exc:
            record["results"].append({"error": str(exc)})
            break
    record["log"] = [tagged(e) for e in t.log]
    record["counters"] = dict(t.counters)
    record["now"] = hexfloat(t.now)
    return record


def _send(agent, kind, payload, route, **kw):
    return {"op": "send", "agent": agent, "kind": kind, "payload": payload, "route": list(route), **kw}


def _adv(until):
    return {"op": "advance", "until": until}


PHYSICAL_SCENARIOS = {
    # transport tests: shared capacity, round robin, FIFO and byte conservation
    "round_robin": ({"profile": "physical", "access_uplink_mbps": 0.008, "contention_enabled": False,
                     "handover_enabled": False, "one_way_propagation_seconds": 0},
                    [_send(a, "data", bytes(1000), ["access_up"]) for a in (0, 0, 0, 1, 1, 2)]
                    + [{"op": "occupancy"}, _adv(1.5), {"op": "occupancy"}, _adv(100),
                       {"op": "occupancy"}]),
    # handovers pause only satellite links; long messages span several windows
    "handover": ({"profile": "physical", "contention_enabled": False},
                 [_adv(15), _send(0, "edge", {}, ["access_up", "access_down"]),
                  _send(1, "cloud", {}, ["satellite_up", "satellite_down"]), _adv(15.01), _adv(15.2),
                  _adv(29.6), _send(2, "big", bytes(1_000_000), ["satellite_up"]),
                  _send(3, "huge", bytes(30_000_000), ["satellite_down", "access_down"]),
                  {"op": "occupancy"}, _adv(30.02), {"op": "occupancy"}, _adv(80),
                  {"op": "handover_windows", "start": 0.0, "end": 100.0},
                  {"op": "handover_windows", "start": 15.03, "end": 44.9},
                  {"op": "handover_windows", "start": 15.06, "end": 30.0},
                  {"op": "handover_windows", "start": 7.0, "end": 14.0}]),
    "handover_off": ({"profile": "physical", "contention_enabled": False, "handover_enabled": False},
                     [_adv(14.9), _send(0, "x", bytes(500_000), ["satellite_up", "access_down"]),
                      _adv(40), {"op": "handover_windows", "start": 0.0, "end": 100.0}]),
    "fragmented_chunks": ({"profile": "physical", "contention_enabled": False,
                           "packet_payload_bytes": 4000, "log_service_chunks": True,
                           "handover_interval_seconds": 2.0, "handover_interruption_seconds": 0.3,
                           "satellite_uplink_mbps": 0.5, "satellite_downlink_mbps": 1.0,
                           "access_uplink_mbps": 2.0, "access_downlink_mbps": 2.0},
                          [_send(0, "a", bytes(20000), ["access_up", "satellite_up", "process:0.25",
                                                        "satellite_down", "access_down"]),
                           _send(1, "b", bytes(9000), ["satellite_up"]),
                           _send(1, "b", bytes(100), ["satellite_up"]),
                           _send(2, "c", bytes(3999), ["access_up", "satellite_up"]),
                           _send(-1, "model_relay", None, ["satellite_down"], wire_n=12000),
                           _adv(0.1), {"op": "occupancy"}, _adv(0.7), {"op": "occupancy"},
                           _send(0, "a", "late", ["satellite_up"]), _adv(1.9),
                           {"op": "occupancy"}, _adv(30), {"op": "occupancy"}]),
    "fragmented_quiet": ({"profile": "physical", "contention_enabled": False,
                          "packet_payload_bytes": 1500, "packet_overhead_bytes": 60,
                          "handover_interval_seconds": 1.0, "handover_interruption_seconds": 0.1,
                          "satellite_uplink_mbps": 0.2},
                         [_send(a, "q", bytes(n), ["satellite_up", "access_down"])
                          for a, n in ((0, 7000), (1, 1500), (2, 1), (0, 3000))]
                         + [_adv(0.05), {"op": "occupancy"}, _adv(5)]),
    "contention": ({"profile": "physical", "delay_steps": 3.0, "seconds_per_step": 0.5,
                    "satellite_uplink_mbps": 0.1},
                   [{"op": "windows", "windows": {"0": [[0.5, 1.5]], "1": [[0.0, 0.4], [2.0, 3.0]]}},
                    _send(0, "report", {"x": 1}, ["access_up"]),
                    _send(1, "report", {"x": 2}, ["satellite_up"]), _adv(0.5),
                    _send(0, "report", {"x": 3}, ["access_up"]),
                    _send(0, "report", {"x": 4}, ["access_up"], delayed=False),
                    _send(1, "report", {"x": 5}, ["satellite_up"]),
                    {"op": "occupancy"}, _adv(2.1), _send(1, "info", (1, 2.5, "z"), ["satellite_up"]),
                    {"op": "occupancy"}, _adv(10), {"op": "occupancy"}]),
    "trace_uplink": ({"profile": "physical", "contention_enabled": False,
                      "uplink_trace": "trace_uplink.npz", "one_way_propagation_seconds": 10.0,
                      "backhaul_time_offset_seconds": 0.5, "handover_interval_seconds": 5.0},
                     [_send(0, "data", bytes(100000), ["satellite_up"]),
                      _send(1, "data", bytes(10), ["access_up", "satellite_up", "process:0.5",
                                                   "satellite_down", "access_down"]),
                      _adv(0.031), _adv(5.04), _adv(12),
                      _send(2, "data", bytes(10), ["satellite_up"], generated_at=11.0),
                      _adv(44.9), _send(0, "data", bytes(10), ["satellite_up"]), _adv(46.0)]),
    # the trace ends at 45.5 s; with the 0.5 s offset a hop entering at 45.2 s is past it
    "trace_past_end": ({"profile": "physical", "contention_enabled": False,
                        "uplink_trace": "trace_uplink.npz", "backhaul_time_offset_seconds": 0.5},
                       [_adv(44.9), _send(0, "data", bytes(10), ["satellite_up"]), _adv(44.95),
                        _adv(45.2), _send(1, "data", bytes(10), ["satellite_up"]), _adv(45.3)]),
    "trace_both": ({"profile": "physical", "contention_enabled": False,
                    "uplink_trace": "trace_uplink.npz", "downlink_trace": "trace_downlink.npz"},
                   [_send(-1, "model_relay", None, ["access_down"], wire_n=200000, version=3),
                    _send(0, "data", [1, 2, 3], ["satellite_up", "satellite_down"]), _adv(16),
                    {"op": "occupancy"}, _send(0, "model", None, ["satellite_down"], wire_n=10)]),
    "trace_controlled": ({"profile": "controlled", "contention_enabled": False,
                          "uplink_trace": "trace_uplink.npz"},
                         [_send(0, "model", None, ["satellite_up"], wire_n=10), _adv(1)]),
    "trace_direction": ({"profile": "physical", "uplink_trace": "trace_downlink.npz"}, []),
    "trace_direction_perfect": ({"profile": "perfect", "downlink_trace": "trace_uplink.npz"}, []),
    "reverse": ({"profile": "physical"}, [_adv(2.0), _adv(1.0)]),
    # advance() also handles events up to 1e-12 s past UNTIL, then sets now = UNTIL
    "advance_tolerance": ({"profile": "physical", "contention_enabled": False},
                          [_send(0, "x", None, ["process:1.0000000000005"]), _adv(1.0)]),
}


def _random_scenario(rng):
    links = ["access_up", "access_down", "satellite_up", "satellite_down"]
    changes = {"profile": "physical",
               "contention_enabled": bool(rng.integers(2)),
               "access_uplink_mbps": float(rng.choice([0.05, 1.0, 50.0])),
               "access_downlink_mbps": float(rng.choice([0.05, 1.0, 50.0])),
               "satellite_uplink_mbps": float(rng.choice([0.02, 0.5, 10.0])),
               "satellite_downlink_mbps": float(rng.choice([0.05, 2.0, 50.0])),
               "handover_enabled": bool(rng.integers(2)),
               "handover_interval_seconds": float(rng.choice([0.7, 3.0, 15.0])),
               # A zero interruption can make Python's _finish_transmission loop
               # forever (see _finish_cases); random scenarios avoid it.
               "handover_interruption_seconds": float(rng.choice([0.05, 0.3])),
               "one_way_propagation_seconds": float(rng.choice([0.0, 0.025])),
               "packet_payload_bytes": int(rng.choice([0, 0, 1500, 3000, 64000])),
               "packet_overhead_bytes": int(rng.choice([0, 48])),
               "log_service_chunks": bool(rng.integers(2)),
               "delay_steps": float(rng.choice([0.0, 2.0])), "seconds_per_step": 0.5}
    ops, now = [], 0.0
    if changes["contention_enabled"]:
        ops.append({"op": "windows", "windows": {str(a): [[float(s), float(s) + 1.0]]
                                                 for a, s in enumerate(rng.uniform(0, 4, 3))}})
    for _ in range(int(rng.integers(15, 40))):
        r = rng.random()
        if r < 0.55:
            route = [links[int(i)] for i in rng.integers(0, 4, int(rng.integers(0, 4)))]
            if rng.random() < 0.3:
                route.insert(int(rng.integers(len(route) + 1)), f"process:{float(rng.choice([0.0, 0.2]))}")
            kw = {"version": int(rng.integers(0, 70000)), "delayed": bool(rng.integers(2))}
            if rng.random() < 0.2:
                kw["wire_n"] = int(rng.choice([0, 1, 1499, 1500, 1501, 70000]))
                payload = None
            else:
                payload = _random_value(rng, depth=2)
            if rng.random() < 0.2:
                kw["generated_at"] = float(now - rng.uniform(0, 1))
            ops.append(_send(int(rng.integers(-1, 4)), str(rng.choice(["report", "information",
                                                                       "mission_request"])),
                             payload, route, **kw))
        elif r < 0.85:
            now += float(rng.choice([0.0, 0.01, 0.25, 1.0, 3.7]))
            ops.append(_adv(now))
        elif r < 0.95:
            ops.append({"op": "occupancy"})
        else:
            a = float(rng.uniform(0, 20))
            ops.append({"op": "handover_windows", "start": a, "end": a + float(rng.uniform(0, 20))})
    ops.append(_adv(now + 200.0))
    ops.append({"op": "occupancy"})
    return changes, ops


def _finish_one(interval, pause, enabled, satellite, start, duration):
    t = Transport(_physical_config(profile="physical", handover_enabled=enabled,
                                   handover_interval_seconds=interval,
                                   handover_interruption_seconds=pause))
    return t._finish_transmission(start, duration, satellite)


def _finish_in_child(args, queue):
    queue.put(_finish_one(*args))


def _finish_or_hang(args, seconds=5.0):
    """Python's result, or None if it does not return within SECONDS.

    Used only for zero interruptions: there, when floor(window / interval)
    rounds down at a window boundary, the loop's state stops changing and
    _finish_transmission never returns. A normal call takes microseconds."""
    import multiprocessing
    ctx = multiprocessing.get_context("fork")
    queue = ctx.Queue()
    child = ctx.Process(target=_finish_in_child, args=(args, queue))
    child.start()
    child.join(seconds)
    if child.is_alive():
        child.kill()
        child.join()
        return None
    return queue.get()


def _finish_cases(rng):
    """Direct Transport._finish_transmission(start, duration, satellite) cases."""
    cases = []
    for k in range(300):
        interval = float(rng.choice([0.5, 1.0, 2.0, 15.0]))
        pause = float(rng.choice([0.05, 0.1, 0.4]))
        enabled = bool(k % 5)
        satellite = bool(k % 7)
        w = int(rng.integers(0, 6))
        start = float(rng.choice([w * interval, w * interval + pause, w * interval + pause / 2,
                                  w * interval - 1e-9, float(rng.uniform(0, 6 * interval))]))
        duration = float(rng.choice([0.0, 1e-15, 1e-3, interval - pause, interval, 2.5 * interval,
                                     float(rng.exponential(interval))]))
        start = max(start, 0.0)
        finish = _finish_one(interval, pause, enabled, satellite, start, duration)
        cases.append({"interval": interval, "pause": pause, "enabled": enabled,
                      "satellite": satellite, "start": hexfloat(start),
                      "duration": hexfloat(duration), "finish": hexfloat(finish)})
    # Zero interruptions: exact windows return; 0.7-second windows at 8.4 s do not,
    # because 12 * 0.7 == 8.399999999999999 and floor(8.399999999999999 / 0.7) == 11.
    for interval, start, duration in ((1.0, 0.5, 2.0), (1.0, 3.0, 0.25), (0.5, 0.2, 1.7),
                                      (0.7, 8.35072, 0.48), (0.7, 0.1, 9.0), (0.7, 8.3, 0.05)):
        args = (interval, 0.0, True, True, start, duration)
        finish = _finish_or_hang(args)
        case = {"interval": interval, "pause": 0.0, "enabled": True, "satellite": True,
                "start": hexfloat(start), "duration": hexfloat(duration)}
        case.update({"finish": hexfloat(finish)} if finish is not None else {"hangs": True})
        cases.append(case)
    return cases


def group_physical():
    """Physical-profile transport replays (link service, handovers, traces)."""
    scenarios = {name: _run_transport(dict(changes), ops)
                 for name, (changes, ops) in PHYSICAL_SCENARIOS.items()}
    rng = np.random.default_rng(1964)
    for k in range(16):
        changes, ops = _random_scenario(rng)
        scenarios[f"random_{k:02d}"] = _run_transport(changes, ops)
    for record in scenarios.values():
        for op in record["ops"]:
            if op["op"] == "send":
                op["payload"] = py_spec(op["payload"])
            for key in ("until", "start", "end", "generated_at"):
                if key in op:
                    op[key] = hexfloat(op[key])
            # 'until' and 'end' are keywords in Octave/MATLAB; jsondecode would rename them.
            for key, safe in (("until", "to"), ("end", "stop")):
                if key in op:
                    op[safe] = op.pop(key)
            if op["op"] == "windows":
                # A list, because JSON object keys "0", "1" are not MATLAB field names.
                op["windows"] = [{"agent": int(a), "spans": [[hexfloat(x) for x in w] for w in ws]}
                                 for a, ws in op["windows"].items()]
    return {"scenarios": scenarios, "finish": _finish_cases(np.random.default_rng(15))}


COMPRESSED = {"env", "encode", "physical", "trace"}
GROUPS = {name[len("group_"):]: fn for name, fn in globals().items() if name.startswith("group_")}


def main(argv):
    OUT.mkdir(parents=True, exist_ok=True)
    selected = argv or list(GROUPS)
    for name in selected:
        data = GROUPS[name]()
        # encode_size copies CPython's C pickler (Modules/_pickle.c), so the
        # Python version and the pickler class that ran are recorded too.
        data["_generator"] = {"script": "matlab/tools/make_fixtures.py", "group": name,
                              "numpy": np.__version__, "python": platform.python_version(),
                              "pickler": f"{pickle.Pickler.__module__}.{pickle.Pickler.__qualname__}"}
        text = json.dumps(data, allow_nan=False, separators=(",", ":")).encode("utf-8")
        if name in COMPRESSED:
            # Deterministic gzip (mtime 0) keeps large fixtures small in git.
            path = OUT / f"{name}.json.gz"
            with open(path, "wb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", mtime=0,
                                                         filename="", compresslevel=9) as stream:
                stream.write(text)
        else:
            path = OUT / f"{name}.json"
            path.write_bytes(text)
        print(f"{path.relative_to(ROOT)}: {path.stat().st_size} bytes")


if __name__ == "__main__":
    main(sys.argv[1:])
