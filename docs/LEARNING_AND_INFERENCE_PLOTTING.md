# Measured learning comparison and exploratory inference

## Rebuild or customize the figures

Run from the repository root:

```powershell
python scripts/plot_learning_and_inference.py --rolling 50 --dpi 220
```

The editable script is `scripts/plot_learning_and_inference.py`. Edit `COLORS`,
`LABELS`, the figure sizes, and the plotting functions directly. Alternative
folders are supported through `--training-root`, `--inference-root`, and
`--output`. This script reads measured records and creates summaries/figures;
it never creates or extends raw experimental observations.
Inference step-metric panels share their y range across information fields
at each agent count, with `MINIMUM_STEP_AXIS_SPAN=5`; this prevents a 0.04-step
fluctuation from filling an entire panel. All plotted extrema remain visible.

Open `output/results/learning-and-inference-20261006-01/results.html` in a
browser for all tables, stage figures, inference sweeps and recorded replays.
Keep the PNG files alongside the HTML. No server is required.

Default results folder: `output/results/learning-and-inference-20261006-01`.
Outputs include `training_stage_summary.csv`, `training_totals.csv`,
`inference_summary.csv`, a plot manifest, and both PNG and PDF figures.
`peer_cutoff_outcomes` plots success, failure-aware PAR-2 and successful
makespan against cutoff duration for each agent count. `peer_cutoff_exposure`
shows the fraction of agents actually affected and their resulting information
age. Small makespan changes use the same minimum five-step axis span as the
other inference panels, rather than magnifying hundredths of a step.

Learning inputs are the four folders under
`output/learning-pilots/fast-curriculum-20261005-01`: `training.jsonl`,
`validation.jsonl`, `validation_cases.jsonl`, and `status.json`.

- Training success includes exploration and deployed model versions; it is
  distinct from the current learner's greedy, fresh-information validation.
- Each phase plot uses episodes and generated steps **within that phase**.
  All success axes span 0–100%. Validation dots occur at the recorded checks.
- `episodes_to_qualification` is absent for an unqualified phase. Eight-agent
  bars are hatched because these budgets ended without qualification.
- Completed training episodes exclude a final unfinished episode. Generated
  joint steps in terminal status include its steps; these counts should differ.
- Successful makespan conditions on success. PAR-2 retains failures at twice
  the 250-step cap (500 steps). Do not substitute one for the other.
- These are four matched-initialization runs with **one training seed (42)**,
  not multi-seed evidence that every delay necessarily degrades learning.

## Inference protocol and reproduction

```powershell
python scripts/run_baseline_inference.py --output output/inference/my-new-baseline-study --device cuda
```

This script uses the exact configuration and frozen package from the Clean
training manifest, and its saved final model. It does not train any model.
The recorded evaluation uses its own saved copy `runner.py` and a launch record.
To run a new evaluation after editing the runner, choose a new output folder;
the saved identity intentionally rejects a changed runner in an existing run.
The recorded experiment can be resumed with its saved `runner.py`.
Do not launch a second process against an output folder while it is active.
The checkpoint failed eight-agent qualification, so the newly requested tests
are explicitly **exploratory** through the existing diagnostic override.
The qualification requirement for a future confirmatory study remains intact.

A transient Windows status-file sharing lock stopped the original process
after 10,258 recorded episodes. It was resumed through the saved
`io_resume.py`, which retries only metadata writes while executing the
unchanged, hash-verified `runner.py`. Completed case IDs are skipped.
The original error log, failed status and both launch identities are retained;
no policy/simulator input or measured episode was replaced. Wall-clock waits
in this wrapper address filesystem locks and do not represent communication
delay or advance virtual mission time.

Phase-exit validation and the new inference tests use different checkpoints
and different case banks: inference always uses the final Clean model after
its partial eight-agent training. Thus its perfect-communication test score
need not equal an earlier phase's graduation score.

Each treatment uses the same 50 held-out cases at each of 2/4/6/8 agents.
Starts, goals and communication reservation seeds are paired, with a maximum
of 250 steps. The cases are distinct from the curriculum validation seeds.

The three suites are:

1. **Planned:** the original 47 conditions (perfect reference; both routes ×
   guidance/intentions/priorities/all × 1/2/5/10/20-step additional delays;
   both routes × physical handover/contention/combined). Two additional
   physical latency-only controls permit handover-versus-latency comparisons.
2. **Orbital:** perfect plus the eight physical conditions, using the existing
   Mont-Tremblant archived-orbit timeline. Each episode uses its configured
   1,000-second offset in that timeline. Satellite identity selection and
   handshake/capacity parameters are simulation assumptions; the geometry is
   derived from archived orbital data, not observed provider handovers.
3. **Peer cutoff:** perfect plus loss of intention/priority updates during
   one or two seeded per-agent windows of 1/2/5/10/20 seconds. Messages during
   a cutoff are discarded, and new messages resume afterward. A* guidance,
   known goals, self-position, local sensing and collision truth stay fresh.

This is 64 treatment configurations × 200 cases = **12,800 episode records**.
Perfect references are recorded per suite to verify cross-suite consistency;
they are the same 200 cases, not additional independent evidence.

An additional **latency-ablation** suite isolates continuous positive physical
access latency for guidance, intentions or priorities individually, with a
perfect reference. Its 800 records bring the total to 13,600. The all-field
latency control comes from the planned suite; it is not rerun for this
diagnostic. All four suites use the same 200 distinct held-out cases.

Robots keep acting with cached inputs. No stopping, recovery controller,
path constraint or reward modification is introduced. Frozen model versions
remain constant. A cutoff of communicated intentions is not blindness to
nearby robots: local robot sensing remains available by design.

Early completion can avoid scheduled windows. Realized exposure, per-field
age, transport events and cached absolute paths are recorded in compressed
episode traces. Do not extend missions or move windows to manufacture effects.
Two seeded cutoff windows can overlap, making continuous information age
longer than one window's nominal duration. For example, the recorded six-agent
case `agents-6-case-042` has 20-step windows at 76–96 and 92–112 seconds for
agent 1; its maximum received-intentions age is 36 seconds. The exposure plots
report these realized ages rather than assuming that every age equals the
configured cutoff duration.

Ordinary physical latency must be separated from additional handshake delay:
compare physical handover to the corresponding physical latency-only control,
not solely to zero-delay perfect communication. At the one-second robot action
cadence, short physical interruptions can leave the action sequence unchanged.

Reports are generated at integer robot-step boundaries; a positively delayed
reply is unavailable to the action at that same boundary. Consequently a
subsecond physical transport delay can produce one-step-old observations.
These synchronous sampling assumptions matter: this experiment does not
establish that a millisecond of latency will cause the same failure in a
robot that waits for a reply before its next action. The latency-ablation
suite identifies which cached inputs drive the observed sensitivity.

The independent `physical_latency_diagnostic.json` reproduces a recorded
failure using its saved actions and checks cached guidance and monotonic
timestamps. The route is retained after an off-route move rather than
silently recomputing A* locally. This can give the fresh-trained policy
alternating guidance and induce oscillation.

Run `scripts/audit_baseline_inference.py` and then
`scripts/audit_inference_transport.py` after completion, before plotting.
The transport audit derives handover holds from actual satellite events with
a 1 ns roundoff tolerance. The original saved runner's positive-roundoff
counts on access links and periodic window helper for orbital data are
retained in raw records but are not used as handover exposure in reports.
Correct event-derived values are in `transport_event_audit.csv`; plotting
uses that sidecar without editing raw records or policy outcomes.

The controlled profile intentionally isolates extra delay from physical link
budgets. UAV-edge and cloud controlled outcomes can therefore coincide. The
physical suites implement the route's actual hops and shared serialization.

The preserved Clean configuration has `delay_steps=5` and
`reservation_steps=2`. The physical-contention arms therefore add five-step
message holds during one or two seeded two-step windows per agent. This is
an assumed resource intervention. Controlled sweeps substitute their
1/2/5/10/20-step holds; peer-cutoff sweeps instead vary the window duration.
For physical runs the legacy per-episode `delay_steps` column is zero because
it was designed as a controlled-sweep coordinate, not as a full protocol
description. The new inference summary exposes `configured_additional_delay_steps`
and `reservation_window_steps` from the actual treatment manifests.

All CSV/JSON summaries are measured. Success differences and PAR-2 differences
use matched cases, with paired bootstrap intervals in suite summary JSON.

The saved Karlstad directional delay recordings each span only about 50
seconds. An empirical-trace mission preflight was rejected because these
cannot cover a 250-second episode. They are **not looped or extrapolated**
to manufacture longer recordings. The optional `--suites empirical` mode
requires longer paired recordings at the same configured paths; it is not
included in the default three-suite mission comparison. The archived
Mont-Tremblant orbital timeline covers six hours and does support these
episodes. The short empirical recordings remain transport-only evidence.

## Local browser hosting

The results page can be opened directly from disk. To host it yourself:

```powershell
python scripts/serve_results.py --directory output/results/learning-and-inference-20261006-01 --port 8973
```

Open `http://127.0.0.1:8973/results.html`. The current verified local server
already uses this port; stop that server or choose a different port before
starting another. It serves only the results folder on loopback. `Ctrl+C`
stops a server started in your terminal.
