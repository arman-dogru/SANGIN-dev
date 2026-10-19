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
    return {"cases": cases, "texts": texts}


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


COMPRESSED = {"env"}
GROUPS = {name[len("group_"):]: fn for name, fn in globals().items() if name.startswith("group_")}


def main(argv):
    OUT.mkdir(parents=True, exist_ok=True)
    selected = argv or list(GROUPS)
    for name in selected:
        data = GROUPS[name]()
        data["_generator"] = {"script": "matlab/tools/make_fixtures.py", "group": name,
                              "numpy": np.__version__}
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
