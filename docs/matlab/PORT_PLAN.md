# MATLAB port plan and handoff

This is the handoff document for the MATLAB port of the UAV–PANAMA
communication staleness study. The work lives on the `matlab` branch, and each
milestone lands through its own `matlab-mN-*` pull request into `matlab`, never
into `main`.

The starter was written **without a MATLAB license**. It is plain MATLAB that
needs no toolboxes, targets R2021b or later, and is verified on GNU Octave 9.4.0.
Whoever continues with a licensed MATLAB should first run the suite there
(`matlab/run_tests.m`), because the Octave run is the only one so far.

## 1. Python source surveyed (commit 9636c81)

| Area | Python | Lines |
|---|---|---:|
| Library | `src/panama_uav/*.py` (21 modules) | 4,997 |
| Experiment, report and plot scripts | `scripts/*.py` (31 scripts) | 8,679 |
| Tests | `tests/*.py` | 1,802 |
| **Total** | | **15,478** |

Configuration is `configs/*.toml` (13 files, two schemas: the study schema read
by `config.load_config`, and the PANAMA-reproduction schema with `extends`
read by `scripts/run_panama_reproduction.py`). Maps are MovingAI `.map` files in
`maps/` and scenarios are `.scen` files in `scens/`.

## 2. Module map

The MATLAB package is `matlab/+panama_uav`. Each Python module has one MATLAB
sub-package or class with the same responsibility.

| Python module | MATLAB location | Responsibility |
|---|---|---|
| `config.py` | `+panama_uav/+config/` (`load_config`, `defaults`, `validate_transport`, `profile`) | Typed config with defaults and study validation |
| (tomllib) | `+panama_uav/+util/toml_decode.m` | TOML subset parser |
| `scenarios.py` | `+panama_uav/+scenarios/` (`load_map`, `load_scenario`, `discover_scenarios`, `first`) | MovingAI maps and scenarios |
| `environment.py` | `+panama_uav/+env/ExperimentEnvironment.m`, `astar_path.m`, `manhattan.m` | Task dynamics, rewards, collisions, observations |
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
|---|---|---|---|
| `tomllib` | configs | `+util/toml_decode.m`: tables, arrays of tables, strings, ints with `_`, floats, booleans, inline and multiline arrays, comments. Integers stay `int64` so int/float is preserved. | (none built in) |
| NumPy | arrays, RNG | Built-in arrays. RNG streams differ (see §5). | — |
| SimPy 4.1.1 | event calendar | `EventCalendar.m`: binary heap keyed by (time, insertion id). It copies SimPy's timing arithmetic `now + max(0, at - now)`. | SimEvents (overkill) |
| `pickle` | wire sizes | `+transport/encode_size.m`: byte-exact pickle protocol-5 size for the value types sent (planned M1b) | — |
| PyTorch | DQN, Adam, Huber | `+nn/` hand-written forward and backward for Conv2d(3×3, pad 1), ReLU, MaxPool2d(2), Flatten, Linear; Huber loss; AdamW with AMSGrad; grad-norm clip; soft target update | **Deep Learning Toolbox** (`dlnetwork`, `dlgradient`, `adamupdate`). Keep the hand-written path as the parity reference. |
| Torch checkpoints | weights | `matlab/tools/export_torch_weights.py` → `.mat` (v5 via SciPy) or JSON; `+models/load_weights.m` | `importNetworkFromPyTorch` (Deep Learning Toolbox Converter for PyTorch) |
| sgp4 2.27, Skyfield 1.55 | `scripts/build_leo_timeline.py`, `scripts/report_leo_full.py` | Port of Vallado SGP4 (OMM → `Satrec`, `sgp4`), plus only the Skyfield calls used (UTC→TT/UT1, TEME→ITRS, `wgs84.latlon`, `altaz`) | **Aerospace Toolbox / Satellite Communications Toolbox** (`satelliteScenario`, `propagateOrbit` with SGP4) |
| ITU-Rpy 0.4.0 | `leo_radio.atmospheric_curves` (`atmospheric_attenuation_slant_path`) | Port of P.676 (gas), P.840 (cloud), P.618 (rain, scintillation), P.453/P.836/P.837/P.1510/P.1511 lookups. Digital-map grids exported once from ITU-Rpy to `.mat` by a Python tool. | **Satellite Communications Toolbox** (`p618Config`, `p618PropagationLosses`, `gaspl`, `cloudpl`, `rainpl`) |
| astropy constants | `c`, `k_B` | Literal constants with a CODATA reference | — |
| NumPy bootstrap | `paired_summary` | Index-resampling bootstrap with the RNG draws injected for parity | **Statistics and Machine Learning Toolbox** (`bootci`, `bootstrp`) |
| Matplotlib | figures | Base MATLAB graphics, `print -dpng` / `exportgraphics` | — |
| `tqdm`, `psutil`, `signal` | progress, monitoring | `fprintf` progress; `onCleanup` for deferred stop | — |

## 4. Milestones

| # | Branch | Scope | Status |
|---|---|---|---|
| M0 | `matlab` | This plan | done |
| M1 | `matlab-m1-core` | Scaffold of the whole package (stubs that raise `panama_uav:notImplemented`), TOML/config, maps/scenarios, A*, UAV geometry, environment step, information caches, `perfect` and `controlled` transport, event calendar, records, fixture generator, parity tests, Octave instructions, README_MATLAB | see checklist |
| M1b | `matlab-m1b-physical` | `physical` profile: link service, satellite handover pauses, pickle-exact wire sizes (`encode_size`), delay traces (`.npz` reader), byte counters and occupancy | next |
| M2 | `matlab-m2-nn` | `+nn` layers and gradients, DQN, Huber, AdamW+AMSGrad, clipping, soft update, torch-weight exporter and loader; forward/backward/optimizer parity | |
| M3 | `matlab-m3-training` | SumTree/PER, Double DQN `learn`, `TrainingSession` with experience upload and snapshot downlink, validation and qualification, MAT-file checkpoints, JSONL/CSV logs | |
| M4 | `matlab-m4-evaluation` | Case bank, `run_episode`, treatments, decision deadline, paired bootstrap summary, `evaluate_suite` | |
| M5 | `matlab-m5-leo` | `OrbitTimeline`, handshake model, SGP4 port and timeline builder, ITU-R port, `handover_study` | |
| M6 | `matlab-m6-reporting` | Reporting figures, HTML replay, `cli.m`, script equivalents | |
| M7 | `matlab-m7-docs` | Full parity table, side-by-side figures, CI | |

## 5. Parity strategy and tolerances

Golden fixtures come from the Python implementation through
`matlab/tools/make_fixtures.py` and are stored as JSON in
`matlab/tests/fixtures/`. JSON cannot hold `Infinity`, so the generator writes
`"inf"`/`"-inf"` strings. `panama_uav.util.fixture_number` maps them back.

**RNG.** NumPy's PCG64 and `Generator.shuffle/integers/choice` are not
reproduced in MATLAB. Wherever Python draws randomness, the MATLAB API accepts
the draws as inputs:
- `ExperimentEnvironment.reset(seed, starts, goals)` takes the starts and goals
  that `np.random.default_rng(seed).shuffle` produced in Python.
- `Transport.schedule_episode(seed, agents, cap, windows)` takes the reservation
  windows that `rng.integers` and `rng.choice` produced.
Without injected draws, MATLAB uses its own `RandStream` with the same
distributions (uniform shuffle; window count uniform on [min, max]; distinct
starts uniform on 1..cap-1). Those runs are only **statistically equivalent**,
not bit-identical.

| Quantity | Tolerance |
|---|---|
| TOML decode of all 13 configs | exact (int64 vs double type preserved) |
| Map grids, scenario starts/goals, A* paths | exact |
| Agent positions, collisions, terminated/truncated, info counters | exact |
| Observations (`single`) | exact (`isequal`) |
| Rewards | abs 1e-12 (all rewards are sums of the same few constants in the same order) |
| UAV position, target, radio SNR map | abs 1e-9 m / 1e-4 dB (libm `exp`/`log10`/`atan` may differ by an ulp; SNR is stored as float32) |
| Event times, information ages, reservation windows | abs 1e-12 s |
| (M1b) wire sizes | exact bytes |
| (M2) NN forward / backward, one AdamW step | rel 1e-5 in float32, 1e-10 in float64 |
| (M5) SGP4 positions | 1e-6 km vs `sgp4` 2.27; ITU attenuation 1e-6 dB |
| (M4) bootstrap intervals | exact with injected indices, otherwise statistical |

## 6. What cannot be ported 1:1

- **Training speed.** PyTorch uses CUDA and vectorized kernels. Hand-written MATLAB
  CPU training is far slower. The 12-hour wall budgets measure Python; a
  MATLAB run cannot reproduce the same number of generated steps in the same
  budget. With Deep Learning Toolbox and a GPU (Parallel Computing Toolbox),
  `dlarray` on `gpuArray` narrows this gap.
- **RNG streams** (above). Learning curves from MATLAB-native seeds are
  statistically, not numerically, comparable.
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
- `containers.Map` is used for integer-keyed dictionaries, with keys as
  `double`.
- No `string` arrays (Octave support is partial); `char` and `cellstr` only.
- No `arguments` blocks (Octave does not parse them); inputs are checked by hand.

## 8. Checklist: done and next

Updated at the end of each milestone. Per-module status and test counts are
in [README_MATLAB.md](../../README_MATLAB.md).

**Done (M0 + M1, verified on Octave 9.4.0, 29/29 tests):**
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
- [x] Fixture generator `matlab/tools/make_fixtures.py`; Octave test shim and runner
- [x] On-demand figure script `matlab/scripts/plot_rollout.m` (output gitignored)

**Next, in order:**
1. [ ] Run `run_tests` on licensed MATLAB R2021b+ and fix any MATLAB/Octave differences
2. [ ] M1b: `physical` profile (`_start`, `_finish_transmission`, link round-robin,
       handover pauses), `encode_size` (pickle-5 byte counts; add a fixture of
       `len(encode(payload))` for report, mission and information payloads),
       `occupancy`, `DelayTrace` (`.npz` reader), `import_trace`
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
8. [ ] M6/M7: reporting, HTML replay, CLI, CI workflow, side-by-side figures

**Known gaps and ambiguities:**
- MATLAB-native RNG draws are only statistically equivalent to NumPy's.
- `Transport.log` entries carry no byte counts until `encode_size` lands.
- The repository README still links to `output/results/...`, which was
  removed on this branch (see the M1 PR); main will be updated separately.
