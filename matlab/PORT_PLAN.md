# MATLAB port plan and handoff

This is the handoff document for the MATLAB port of the UAV–PANAMA
communication staleness study. The work lives on the `matlab-port-v2`
branch, which starts from the rewritten `main` at 64b5964. Each milestone
lands through its own `matlab-port-v2-mN` pull request into `matlab-port-v2`,
never into `main`. The port adds only `matlab/` (this plan included) and
`README_MATLAB.md`; it does not change or restore any other file.

The starter was written **without a MATLAB license**. It is plain MATLAB that
needs no toolboxes, targets R2021b or later, and is verified on GNU Octave 9.4.0.
Whoever continues with a licensed MATLAB should first run the suite there
(`matlab/run_tests.m`), because the Octave run is the only one so far.

## 1. Python source surveyed (commit 64b5964)

| Area | Python | Lines |
| --- | --- | ---: |
| Library | `src/panama_uav/*.py` (22 files, 21 modules plus `__init__`) | 4,997 |
| Experiment, report and plot scripts | `scripts/*.py` (29 scripts) | 5,977 |
| Tests | `tests/*.py` (11 files) | 1,170 |
| **Total** | | **12,144** |

Configuration is `configs/*.toml` (4 files: base, fast_pilot, leo_learning,
leo_tremblant), all in the study schema read by `config.load_config`. The
rejection rules of `load_config` are pinned with 24 small synthetic TOML
texts in the `config` fixture group (at least one per rule), since no
committed config is rejected. `ConfigTest` compares Python's `ValueError`
message word for word; the unknown key is a Python `TypeError` (dataclass
constructor), where only the rejection is compared.

Coverage is measured, not assumed: `python matlab/tools/mutation_sweep.py`
disables each rule in turn in a temporary copy of the tree and runs the
relevant test file. It reports each mutant as killed (an assertion failed),
ERRORED (a crash), TIMEOUT or SURVIVED, and counts only assertion kills.
Measured on fresh clones of matlab-m1b-fixes (67c6b0c for every group;
npy rerun at 4348c03 after its test stopped erroring on a rejected valid
file): config 20/20, toml 29/29, env 2/2, encode 19/19, npy 6/6, trace 6/6
and transport 30/30 killed by assertions, with 0 errored, 0 timed out and
0 survived. Mutants that cannot change a
result, or whose only effect is an endless loop, are listed (with the
reason) at the end of the sweep's MUTANTS table.
`python matlab/tools/toml_corpus.py` compares toml_decode with tomllib on
seeded random byte documents within the supported subset (including control
characters and invalid UTF-8): at 84dba21, 0 of 3,000 documents mismatched for
each of seeds 1, 2 and 3 (157, 166 and 132 of them rejected as invalid UTF-8);
the decoder at feefd8f, given the same UTF-8 check, mismatched 444 of 3,000 on
seed 1 (measured at 7b2516e). Both tools write to `matlab/output/`
(gitignored). Rerun them when a rule changes, add a mutant for a new rule,
and update this paragraph with the commit you measured.

Maps are MovingAI `.map` files in `maps/` (13 files) and scenarios are `.scen`
files in `scens/` (3 sets).

## 2. Module map

The MATLAB package is `matlab/+panama_uav`. Each Python module has one MATLAB
sub-package or class with the same responsibility.

| Python module | MATLAB location | Responsibility |
| --- | --- | --- |
| `config.py` | `+panama_uav/+config/` (`load_config`, `defaults`, `validate_transport`, `profile`) | Typed config with defaults and study validation |
| (tomllib) | `+panama_uav/+util/toml_decode.m` | TOML subset parser |
| `scenarios.py` | `+panama_uav/+scenarios/` (`load_map`, `load_scenario`, `discover_scenarios`, `first`) | MovingAI maps and scenarios |
| `environment.py` | `+panama_uav/+environment/ExperimentEnvironment.m`, `astar_path.m`, `manhattan.m` | Task dynamics, rewards, collisions, observations |
| `information.py` | `+panama_uav/+information/` (`InformationCache`, `Guidance`, `MissionCommunication`) | Receiver caches, staleness, mission routes |
| `transport.py` | `+panama_uav/+transport/` (`Transport`, `DelayTrace`, `import_trace`, `encode_size`) | Virtual-time links, reservations, FIFO buffering |
| `event_calendar.py` | `+panama_uav/+transport/EventCalendar.m` | Minimal discrete-event scheduler (SimPy replacement) |
| `uav.py` | `+panama_uav/+uav/` (`AirToGroundModel`, `UAVController`) | Air-to-ground geometry and UAV placement |
| `radio.py` | `+panama_uav/+radio/` (`normalize_quality`, `RadioSnapshot`) | Radio quality map |
| `records.py` | `+panama_uav/+records/` (`append_jsonl`, `read_jsonl`, `write_json`, `export_csv`, `sha256`) | JSONL/CSV records |
| `models.py` | `+panama_uav/+models/` (`DQN`, `select_action(s)`, `observation_tensors`) | Dual-stream DQN |
| (torch.nn) | `+panama_uav/+nn/` (`conv2d`, `relu`, `maxpool2d`, `linear`, backward of each, `huber`, `AdamW`, `clip_grad_norm`) | Hand-written NN layers, gradients and optimizer |
| `replay.py` | `+panama_uav/+replay/` (`SumTree`, `PrioritizedReplayBuffer`) | Prioritized experience replay |
| `learning.py` | `+panama_uav/+learning/learn.m` | Double-DQN update |
| `training.py` | `+panama_uav/+training/` (`TrainingSession`, `train_policy`, `validate`, `compare_training`, …) | Curriculum training and learning transport |
| `evaluation.py` | `+panama_uav/+evaluation/` (`case_bank`, `run_episode`, `treatments`, `paired_summary`, `evaluate_suite`) | Frozen-policy inference |
| `leo.py` | `+panama_uav/+leo/` (`OrbitTimeline`, `observer_ecef`, `teme_to_ecef`, `link_geometry`, `handshake`) | Orbital backhaul timeline |
| `leo_radio.py` | `+panama_uav/+leo_radio/` (`atmospheric_curves`, `link_budget`, `provenance`) + `+itur/` | ITU-R link budget |
| `handover_study.py` | `+panama_uav/+handover_study/derive_timeline.m` | Derived handover timelines |
| `reporting.py` | `+panama_uav/+reporting/` (`report_training`, `report_evaluation`, `rolling`) | Figures and summaries |
| `replay_viewer.py` | `+panama_uav/+replay_viewer/create_replay.m` | Self-contained HTML replay |
| `cli.py`, `__main__.py` | `+panama_uav/cli.m` | Command dispatcher |
| `scripts/*.py` | `matlab/scripts/*.m` (later milestones) | Study runners and plots |

## 3. Dependency replacements

| Python dependency | Used for | MATLAB replacement (no toolbox) | With a license, could use |
| --- | --- | --- | --- |
| `tomllib` | configs | `+util/toml_decode.m`: tables, arrays of tables, strings, ints with `_`, floats, booleans, inline and multiline arrays, comments. Integers stay `int64` so int/float is preserved. | (none built in) |
| NumPy `.npz` | delay traces | `+util/read_npz.m` (built-in `unzip`; on Octave the system `unzip` program) and `+util/read_npy.m` (format 1.0–3.0, little-endian numeric, bool, `<U` strings; object arrays refused as with `allow_pickle=False`) | — |
| NumPy | arrays, RNG | Built-in arrays; `+util/Xorshift128.m` replaces `np.random.default_rng` (same distributions, different stream; see §5) | — |
| SimPy 4.1.1 | event calendar | `EventCalendar.m`: binary heap keyed by (time, insertion id). It copies SimPy's timing arithmetic `now + max(0, at - now)`. | SimEvents (overkill) |
| `pickle` | wire sizes | `+transport/encode_size.m`: byte-exact length of a protocol-5, fast-mode pickle (CPython's C pickler, including 64 KiB framing) for None, bool, int, float, str, bytes (`PyBytes`), list, tuple (`PyTuple`) and str-keyed dict; mission payloads follow in M1b-2 | — |
| PyTorch | DQN, Adam, Huber | `+nn/` hand-written forward and backward for Conv2d(3×3, pad 1), ReLU, MaxPool2d(2), Flatten, Linear; Huber loss; AdamW with AMSGrad; grad-norm clip; soft target update | **Deep Learning Toolbox** (`dlnetwork`, `dlgradient`, `adamupdate`). Keep the hand-written path as the parity reference. |
| Torch checkpoints | weights | *Planned for M2, not written yet:* `matlab/tools/export_torch_weights.py` → `.mat` (v5 via SciPy) or JSON, read by `+models/load_weights.m` (currently a stub) | `importNetworkFromPyTorch` (Deep Learning Toolbox Converter for PyTorch) |
| sgp4 2.27, Skyfield 1.55 | `scripts/build_leo_timeline.py`, `scripts/report_leo_full.py` | Port of Vallado SGP4 (OMM → `Satrec`, `sgp4`), plus only the Skyfield calls used (UTC→TT/UT1, TEME→ITRS, `wgs84.latlon`, `altaz`) | **Aerospace Toolbox / Satellite Communications Toolbox** (`satelliteScenario`, `propagateOrbit` with SGP4) |
| ITU-Rpy 0.4.0 | `leo_radio.atmospheric_curves` (`atmospheric_attenuation_slant_path`) | Port of P.676 (gas), P.840 (cloud), P.618 (rain, scintillation), P.453/P.836/P.837/P.1510/P.1511 lookups. Digital-map grids exported once from ITU-Rpy to `.mat` by a Python tool. | **Satellite Communications Toolbox** (`p618Config`, `p618PropagationLosses`, `gaspl`, `cloudpl`, `rainpl`) |
| astropy constants | `c`, `k_B` | Literal constants with a CODATA reference | — |
| NumPy bootstrap | `paired_summary` | Index-resampling bootstrap with the RNG draws injected for parity | **Statistics and Machine Learning Toolbox** (`bootci`, `bootstrp`) |
| Matplotlib | figures | Base MATLAB graphics, `print -dpng` / `exportgraphics` | — |
| `tqdm`, `psutil`, `signal` | progress, monitoring | `fprintf` progress; `onCleanup` for deferred stop | — |

## 4. Milestones

| # | Branch | Scope | Status |
| --- | --- | --- | --- |
| M0 | `matlab-port-v2` | This plan | done |
| M1 | `matlab-port-v2-m1` | Scaffold of the whole package (stubs that raise `panama_uav:notImplemented`), TOML/config, maps/scenarios, A*, UAV geometry, environment step, information caches, `perfect` and `controlled` transport, event calendar, portable RNG, fixture generator, parity tests, Octave instructions, README_MATLAB | see checklist |
| M1b-1 | `matlab-m1b` | `physical` profile without orbital timelines: link service (shared capacity, per-agent round robin, fragmentation and packet overhead, propagation), periodic satellite handover pauses and windows, `encode_size` for plain value types, delay traces (`.npz` reader, `DelayTrace`, trace replay), byte counters and occupancy | done |
| M1b-2 | `matlab-m1b-2` | Wire sizes of the mission payloads (int-keyed dicts, `Guidance`, tuples of ints) so `MissionCommunication` runs on the physical profile, physical-profile environment rollouts in `EnvironmentParityTest`, `import_trace` (`np.loadtxt` parsing, `.npz` writer, `+records/sha256`) | next |
| M2 | `matlab-port-v2-m2` | `+nn` layers and gradients, DQN, Huber, AdamW+AMSGrad, clipping, soft update, torch-weight exporter and loader; forward/backward/optimizer parity | |
| M3 | `matlab-port-v2-m3` | SumTree/PER, Double DQN `learn`, `TrainingSession` with experience upload and snapshot downlink, validation and qualification, MAT-file checkpoints, `+records` (JSONL/CSV, sha256) | |
| M4 | `matlab-port-v2-m4` | Case bank, `run_episode`, treatments, decision deadline, paired bootstrap summary, `evaluate_suite` | |
| M5 | `matlab-port-v2-m5` | `OrbitTimeline`, handshake model, SGP4 port and timeline builder, ITU-R port, `handover_study` | |
| M6 | `matlab-port-v2-m6` | Reporting figures, HTML replay, `cli.m`, script equivalents | |
| M7 | `matlab-port-v2-m7` | Full parity table, side-by-side figures, CI (Octave job with `timeout-minutes`; see §8) | |

## 5. Parity strategy and tolerances

Golden fixtures come from the Python implementation through
`matlab/tools/make_fixtures.py` and are stored as JSON in
`matlab/tests/fixtures/`. JSON cannot hold `Infinity`, so the generator writes
`"inf"`/`"-inf"` strings. `panama_uav.util.fixture_number` maps them back.

**RNG.** NumPy's PCG64 and `Generator.shuffle/integers/choice` are not
reproduced. There are two modes:

1. *Exact parity with Python (tests).* Inject the NumPy draws through the one
   entry point a caller needs, `ExperimentEnvironment.reset`:
   `env.reset('starts', S, 'goals', G, 'windows', W)`, with `S`/`G` the N-by-2
   zero-based cells Python's `self.rng.shuffle` produced and `W` a 1-by-N cell
   of K-by-2 `[start end]` reservation windows from `Transport.schedule_episode`.
   `reset` forwards `W` through `MissionCommunication` to
   `Transport.schedule_episode(seed, agents, cap, windows)`.
2. *Native MATLAB draws.* Without injection, the port follows Python's
   generator **semantics** with its own portable stream,
   `panama_uav.util.Xorshift128` (shift/xor only, so MATLAB and Octave give
   bit-identical streams; `RngTest` checks it against a pure-Python reference
   and, independently, against the first ten outputs of Marsaglia's published
   xor128 state through `Xorshift128.from_state`):
   - the constructor seeds the environment's generator with `seed`;
     `reset()` with no seed keeps advancing it, so successive episodes differ
     (Python `environment.py:112,191`; used by `training.py:513` and
     `evaluation.py:27`); `reset('seed', s)` replaces it;
   - reservation windows come from a fresh `Xorshift128(seed)` on every reset,
     with `seed` the base seed or the explicit one, like Python's
     `np.random.default_rng(seed)` in `schedule_episode`.
   The same seed therefore gives the same episode sequence on MATLAB and
   Octave, but **not** the episodes NumPy produces for that seed. The
   distributions match: a uniform shuffle of free cells with pairs popped from
   the end, a window count uniform on `[windows_min, windows_max]`, and
   distinct window starts uniform on 1..cap-1. MATLAB-native runs are
   comparable to Python runs only statistically.

| Quantity | Tolerance |
| --- | --- |
| TOML decode of all 4 configs | exact (int64 vs double type preserved) |
| Map grids, scenario starts/goals, A* paths | exact |
| Agent positions, collisions, terminated/truncated, info counters | exact |
| Observations (`single`) | exact (`isequal`) |
| Rewards | abs 1e-12 (all rewards are sums of the same few constants in the same order) |
| UAV position, target, radio SNR map | abs 1e-9 m / 1e-4 dB (libm `exp`/`log10`/`atan` may differ by an ulp; SNR is stored as float32) |
| Event times, information ages, reservation windows | abs 1e-12 s |
| Wire sizes (`encode_size`) | exact bytes (an integer; one byte changes every service time) |
| Physical transport: log times, durations, handover and queue seconds, occupancy, `finish_transmission` | bit-exact (0 ulp): the port performs the same IEEE-754 double operations in the same order (capacity·1e6, bytes·8/bps, floor/ceil, the same sums) and calls no libm function |
| Delay traces: stored arrays, `DelayTrace.delay` | bit-exact: bytes are copied and lookups only compare |
| (M2) NN forward / backward, one AdamW step | rel 1e-5 in float32, 1e-10 in float64 |
| (M5) SGP4 positions | 1e-6 km vs `sgp4` 2.27; ITU attenuation 1e-6 dB |
| (M4) bootstrap intervals | exact with injected indices, otherwise statistical |

## 6. What cannot be ported 1:1

- **Training speed.** PyTorch uses CUDA and vectorized kernels. Hand-written MATLAB
  CPU training is far slower. The 12-hour wall budgets measure Python; a
  MATLAB run cannot reproduce the same number of generated steps in the same
  budget. With Deep Learning Toolbox and a GPU (Parallel Computing Toolbox),
  `dlarray` on `gpuArray` narrows this gap.
- **RNG streams** (above). MATLAB and Octave agree with each other bit for
  bit, but learning curves from MATLAB-native seeds are only statistically
  comparable to Python's.
- **Checkpoints.** Python checkpoints pickle Python objects. MATLAB checkpoints
  are `.mat` files and cannot resume a Python run; only weights cross over.
- **Wire format.** Sizes come from pickle protocol 5. MATLAB reproduces the
  byte *count* for the payload types used, not a pickle reader.
- **Float32 GEMM order.** Torch's reductions differ from MATLAB's BLAS, so NN
  parity uses tolerances, not equality.
- **Library-backed LEO.** ITU-R digital maps and the SGP4 code are reproduced,
  not linked; versions are pinned to ITU-Rpy 0.4.0 and sgp4 2.27.

## 7. MATLAB/Octave compatibility notes

- Tests subclass `matlab.unittest.TestCase`. On Octave, `matlab/compat/octave/`
  is added to the path and provides a small `matlab.unittest.TestCase` shim
  (verifyEqual with `AbsTol`, verifyTrue, verifyFalse, verifyError, …) and a runner.
  Test method names start with `test` so the Octave runner can find them. On
  MATLAB the shim is never on the path.
- `jsondecode`/`jsonencode` exist in both (MATLAB R2016b+, Octave 7+).
- Integer-keyed Python dicts become cells or vectors indexed by `id + 1`
  (no `containers.Map`).
- No `string` arrays (Octave support is partial); `char` and `cellstr` only.
- No `arguments` blocks (Octave does not parse them); name-value options go
  through `+util/parse_options.m`, which rejects unknown names.
- No `RandStream`/`rng` (Octave lacks `RandStream`, and MATLAB's and Octave's
  `rand('twister')` differ); use `+util/Xorshift128`.
- `jsondecode` renames JSON keys that are not valid MATLAB names with
  `matlab.lang.makeValidName` (`end` becomes `xEnd`, and on Octave `until`
  becomes `xUntil`), so fixture ops use `to`/`stop` and log comparisons map
  field names the same way.
- `.npz` files are ZIP archives with ZIP64 local headers. MATLAB's `unzip`
  is built in (not yet run here: no license); Octave's calls the system
  `unzip` program (`apt-get install unzip`), which reads them.

## 8. Checklist: done and next

Updated at the end of each milestone. Per-module status and test counts are
in [README_MATLAB.md](../README_MATLAB.md).

**Done (M0 + M1, verified on Octave 9.4.0; see README_MATLAB for the test count):**
- [x] Port plan (this file)
- [x] Full `+panama_uav` scaffold: every Python module has a MATLAB
      counterpart. 59 stubs name their Python source and raise
      `panama_uav:notImplemented` (`ScaffoldTest`)
- [x] TOML subset decoder, `load_config`, `profile`, transport validation
- [x] MovingAI maps and scenarios; A* with Python's heap tie-breaking
- [x] Air-to-ground model, UAV controller, radio snapshot
- [x] `ExperimentEnvironment`: reset (injectable draws), collisions, rewards, observations
- [x] Information caches, guidance consumption, mission routes (UAV and cloud), staleness
- [x] `EventCalendar` (SimPy replacement); `Transport` for the `perfect` and `controlled` profiles
- [x] Portable seeded generator `+util/Xorshift128` with Python seedless-reset semantics
- [x] Marsaglia (2003) reference outputs and synthetic config rejection cases
- [x] Fixture generator `matlab/tools/make_fixtures.py`; class-strict Octave test shim and runner
- [x] On-demand figure script `matlab/scripts/plot_rollout.m` (output gitignored)
- [x] M1b-1: `physical` profile without orbital timelines (`Transport._start`,
      `_finish_transmission` as `finish_transmission`, round robin,
      fragmentation, handover pauses and `handover_windows`), `encode_size`
      for plain value types, `DelayTrace` with the `.npz` reader and trace
      replay, byte counters, `occupancy` (`EncodeTest`, `NpyTest`, `TraceTest`, `TransportTest`)

**Next, in order:**
1. [ ] Run `run_tests` on licensed MATLAB R2021b+ and fix any MATLAB/Octave differences
2. [ ] M1b-2: wire sizes of the mission payloads. Python's report is a dict
       of tuples of ints, a list of tuples, floats and a bool; the
       mission_compute and information payloads add dicts keyed by agent id
       and `Guidance` (a dataclass, pickled by class reference and state).
       MATLAB's `MissionCommunication` must hand `encode_size` typed values
       (`PyTuple` of int64, an int-keyed dict type, a Guidance mapping); then
       add physical-profile cases to `EnvironmentParityTest` and fixtures of
       `len(encode(payload))` for the report, mission and information
       payloads. Port `import_trace` (np.loadtxt with `dtype=str`: `#`
       comments, comma detection on the first line only; the `.npz` writer;
       `+records/sha256`, now a stub)
3. [ ] `MissionCommunication.prepare_decision` (decision deadline)
4. [ ] M2: `+nn` and `DQN` with forward/backward/AdamW parity. Add
       `export_torch_weights.py` and fixtures with `torch.manual_seed`.
       Consider Deep Learning Toolbox (`dlnetwork`, `dlgradient`, `adamupdate`)
       as the fast path, keeping the hand-written one as reference
5. [ ] M3: PER, `learn`, `TrainingSession`, records
6. [ ] M4: evaluation and bootstrap (`bootci` with Statistics Toolbox, if licensed)
7. [ ] M5: LEO. Satellite Communications / Aerospace Toolbox (`satelliteScenario`,
       SGP4 propagator, `p618PropagationLosses`) can replace the hand ports;
       keep parity fixtures against `sgp4` 2.27 and ITU-Rpy 0.4.0 either way
8. [ ] M6/M7: reporting, HTML replay, CLI, CI workflow, side-by-side figures.
       Give the CI job a `timeout-minutes` (the suite takes about 2.5 min on
       Octave, so 15 is ample): `astar_path` has no closed set, and the
       mutation `>=` → `>` at `astar_path.m:58` makes `MapsTest` loop forever
       instead of failing

**Known gaps and ambiguities:**
- MATLAB-native episodes for a seed are not NumPy's episodes for that seed (identical between MATLAB and Octave).
- Payloads that `encode_size` does not map yet (the mission payloads,
  M1b-2) make the physical profile raise `panama_uav:notImplemented`; the
  other profiles, which never use sizes for timing, log NaN bytes and NaN
  byte counters for them.
- **Python transport behaviour kept as is (documented in the code):**
  - `_finish_transmission` never returns with a zero (or sub-ulp)
    `handover_interruption_seconds` when `floor(window / interval)` rounds
    down at a window boundary: 12 × 0.7 = 8.399999999999999 and
    floor(8.399999999999999 / 0.7) = 11, so the loop finds no time
    available and does not move (start 8.35072 s, duration 0.48 s, interval
    0.7 s). The port raises `panama_uav:transport` at that fixed point
    instead of hanging; `TransportTest` pins two such cases, recorded as
    "does not return within 5 s" by the generator. All four configs use
    the default 0.05 s interruption.
  - A remaining time of at most 1e-14 s counts as done, so such a residue
    still waits out the pause it reached; a zero duration returns at once
    even inside a pause.
  - `packet_overhead_bytes` (default 48) applies only when
    `packet_payload_bytes > 0`; unfragmented messages carry no overhead.
  - A traced satellite hop replaces link service entirely: no capacity,
    no handover pause, no `one_way_propagation_seconds`, and its bytes are
    not in `hop_bytes_transmitted`. Handover events are still logged, with
    `affects_links` listing only the untraced satellite links.
  - Traces are loaded and their direction checked for every profile, but
    replayed only by the physical one.
  - `DelayTrace.delay` does not check that timestamps are sorted
    (`import_trace` guarantees it); a NaN time passes the range check and
    gets the last delay (NumPy's `searchsorted` sorts NaN last).
  - Without an orbital timeline, the link eligibility test
    `ready_at <= now + 1e-12` is always true and
    `max(latest_arrival, finish + propagation)` always takes the new value;
    both are kept for M5.
  - `occupancy` counts a message in its last chunk under `in_flight` (its
    next-hop event is already scheduled), not under its link.
  - CPython's `batch_dict_exact` writes an extra empty `MARK SETITEMS` for
    dicts with a positive multiple of 1000 items; lists get no such batch.
- **Inherited off-by-one (kept on purpose).** `_random_starts_and_goals` in
  `environment.py` guards with `len(cells) < num_agents`, but an odd agent
  count pops `num_agents + 1` cells (each pair pops two, the odd agent pops a
  start and a goal). With exactly `num_agents` free cells and an odd count,
  Python raises `IndexError` past the guard. The port keeps the same guard, so
  it fails at the same point with an indexing error rather than
  `panama_uav:environment`. Fix it in Python and MATLAB together.
  `RngTest/testOddAgentGuardOffByOneLikePython` pins the current behaviour.
- Generated output stays out of Git: figures go to `matlab/output/`, which
  `matlab/.gitignore` ignores, and the repository's `/output/` rule covers the
  Python side.
