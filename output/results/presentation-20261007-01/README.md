# Presentation figures from measured results

The PNG files are direct high-resolution plot exports suitable for slides.
PDF and editable SVG versions accompany every image. Images identify phases
only as Stage 1–4; agent counts and map names do not appear in their visible
text. The stage mapping remains in the manifest for reproducibility.

## Rebuild and customize

From the repository root:

```powershell
python scripts/plot_presentation_results.py --dpi 220 --rolling 50
```

Edit `COLORS`, `TRAINING_LABELS`, `COMPARISONS`, figure sizes and plotting
functions in that script. `--training-root`, `--inference-root` and `--output`
select alternative recorded runs or destinations. Open `index.html` for a
local gallery. PNG exports are 3,520 pixels wide at the default resolution.

## Training figures

- `training_stage_progress`: curriculum qualification against generated
  environment steps and elapsed wall-clock time, side by side.
- `training_stage_progress_environment_steps` and
  `training_stage_progress_wallclock`: separate versions of those panels.
- `training_success_environment_steps` and `training_success_wallclock`:
  success curves separately for each stage, with greedy validation dots.

One environment step is one simultaneous joint action; it is not one
transition per robot. Step-progress plots use the common recorded range
0–305,049. Wall-clock plots include initialization and validation in each
three-hour allocation. Within-stage elapsed time begins at the preceding
qualification check, so it includes subsequent setup work.

Lines in success figures average the most recent 50 training episodes.
Validation dots summarize 200 greedy cases. Training uses exploration and
deployed weights; validation evaluates current learner weights with fresh
mission information. A high training mean does not imply greedy
qualification. Qualification requires at least 95%, after the minimum
training allocation. No run qualified Stage 4, and no progression line is
extended to indicate graduation.

The four conditions use matched seed-42 initialization. The delayed arms
add five-step holds during seeded two-step windows to experience uploads,
model deployments, or both. Mission observations remain fresh. This is a
controlled learning comparison, not an empirical Starlink training run.

## Inference bar charts

All comparisons use the frozen final Clean checkpoint and the same 50
held-out cases per stage, with a 250-step cap. Every case is checked against
the reference's seed, starts and goals before plotting.

- **Average episode length:** mean environment steps across every episode,
  including failed episodes at their recorded length.
- **Success rate:** successful episodes divided by all cases; the axis is
  always 0–100%.
- **Successful makespan:** mean time until all goals are occupied,
  conditional on success. It is not the sum of individual robot path lengths.
  Different treatments can have different successful-case subsets.
- **PAR-2:** additionally retained in the exported CSV, with failures assigned
  500 steps, for a failure-aware comparison.

Whiskers are marginal 95% intervals: Wilson intervals for success and
case-bootstrap percentile intervals for lengths, using 5,000 resamples.
They are not confidence intervals for paired treatment differences. The
original results report retains those paired comparisons. Identical outcome
vectors use the same bootstrap draws.

`inference_mission_delay_5` and `inference_mission_delay_20` compare perfect
communication against occasional extra delay in all three inputs: task
guidance, intentions and priorities. `inference_mission_delay_sweep` shows
all five severities. `inference_stale_fields_20` isolates the delayed inputs.
Cloud controlled routing does not charge physical propagation or link
capacity; its outcomes coincide with the controlled UAV-edge route.

`inference_peer_cutoff_20` discards intention/priority updates in one or two
seeded 20-step windows. Guidance and local sensing stay fresh. Early
completion can avoid scheduled exposure; overlapping windows can yield an
age greater than the nominal window duration.

`inference_orbital_delay` compares zero delay with continuous cloud transport
derived from the archived orbital timeline, with and without modeled
handovers. `inference_handover_increment` isolates handover from ordinary
latency. `inference_orbital_contention` adds controlled contention separately.
The ordinary latency and handover outcomes are identical for these cases;
the figures preserve that observation.

The physical-latency results depend on report/action timing: reports are
generated at integer action boundaries, so even a short positive delay can
make the next action use the previous report. Retaining cached guidance after
an off-route move can cause oscillation in this fresh-information-trained
policy. These results do not establish that millisecond delays universally
cause comparable failures in real robots.

## Provenance and scope

Source learning records are under
`output/learning-pilots/fast-curriculum-20261005-01/{condition}`. Inference
records are under `output/inference/baseline-20261006-01/{suite}/{condition}`.
The script reads JSONL directly, computes the plotted metrics, and exports
`inference_bar_data.csv` and `training_stage_progress.csv`. `manifest.json`
records source hashes, case-pairing checks, visible figure text and plotting
parameters. No experiment records are edited or synthetically extended.

Stage 1–4 correspond to 2/4/6/8 robots on the fixed
`random-32-32-10.map`; these identities are deliberately outside the images.
The inference study is exploratory because the final Clean model did not
qualify every curriculum phase. The learning comparison has one training
seed, not multiple independent training replications.

The archived orbital elements support the six-hour derived timeline. The
currently imported measured one-way delay pair spans about 50 seconds and
has only been used for transport sensitivity. It is not the source of these
full-episode policy outcomes. Longer, continuous measured segments are needed
for the planned trace-driven mission study.

The short reusable experiment description is in
`EXPERIMENT_ASSUMPTIONS.md`, with links to datasets and primary papers.
