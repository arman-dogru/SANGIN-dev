# PANAMA from-scratch reproduction

This protocol trains new policies from random initialization. It does not load
any retained checkpoint. Its purpose is to reproduce the qualitative PANAMA
result on the four requested MovingAI random maps before interpreting the UAV
comparison.

## Fixed experiment design

### Weekend four-setup comparison

The comparison configuration gives the three trained policies a combined
46.5-hour ceiling, then evaluates the four setups on identical scenarios. Start
with a new schema-v3 run ID:

```bash
python3 scripts/run_panama_reproduction.py --config configs/panama_comparison.toml --phase preflight --run-id panama-comparison-v3
python3 scripts/run_panama_reproduction.py --config configs/panama_comparison.toml --phase weekend --run-id panama-comparison-v3
```

This starts fresh policies for setups 1, 2, and 4 with seed 42. Setup 3 reuses
setup 1 and needs no training. Each policy stops at 12 million joint steps or
15.5 cumulative training hours, whichever comes first: 46.5 training hours total,
with 1.5 hours reserved toward a roughly 48-hour weekend for preflight and
cleanup. The timer is cooperative, so this is not a guaranteed hard process
deadline. Validation counts against each policy's time budget. No evaluation
or reporting is automatically appended to the weekend run.

The configuration uses two actors, 300,000 replay transitions, exploration decay
over three million steps, and 100 greedy validation episodes every 500 training episodes.
It preserves all eight original curriculum stages and their graduation criteria.
Setup 4 also receives a small -0.02 cost for a full UAV movement step, scaled by
the fraction of the configured 20 m step limit used. This makes lower UAV travel
an explicit comparison objective. The full reproduction configuration keeps
this extension at zero.
Policies may finish at different stages; failed graduation is never forced.
Budget exhaustion is a normal partial-training result and the next policy starts
automatically. A real worker/training error still stops the runner.

While training, or after it stops, build the validation trend dashboard:

```bash
python3 scripts/run_panama_reproduction.py --config configs/panama_comparison.toml --phase progress --run-id panama-comparison-v3
```

This writes `training_validation_progress.csv` and
`plots/training_progress.png`. They track success, PAR-2, A*-normalized path
efficiency, lower-tail link quality, normalized blackouts, and normalized UAV
travel as training advances.

Then run the matched held-out comparison and report:

```bash
python3 scripts/run_panama_reproduction.py --config configs/panama_comparison.toml --phase evaluate --run-id panama-comparison-v3
python3 scripts/run_panama_reproduction.py --config configs/panama_comparison.toml --phase report --run-id panama-comparison-v3
```

The proof-of-concept evaluation uses 4, 8, and 12 agents on all four random maps.
It retains scalar metrics for every episode and detailed traces for up to 20
failures per setup. If a policy reached its wall-time limit before graduating,
evaluation is still allowed for this configuration, but every episode records
the policy's stage, training steps, wall time, and completion status. The report
labels the result partial. It must not be described as a completed reproduction.

Use the same command and run ID to resume; checkpointed steps and consumed time
are retained. A crash can lose work since the most recent save. Reward schema v2
and unfinished-agent replay require a new run ID rather than either prior pilot
or weekend run.

### Start with a bounded learning pilot

Use this before committing to reproduction training:

```bash
python3 scripts/run_panama_reproduction.py --config configs/panama_pilot.toml --phase train-mapf --run-id panama-pilot-v2
```

The pilot trains only setup 1, seed 42, from scratch for at most 100,000 joint
steps (1/800 of the full per-policy ceiling) or one hour of cumulative training
wall time, whichever comes first. The timer includes initialization, actor startup,
learning and validation; radio preflight and final checkpoint/worker cleanup add
overhead. This is a cooperative limit checked between operations, not a process
kill deadline. Resuming the same run retains its consumed time budget.

The pilot retains the original curriculum and graduation requirements. It is
expected to remain in the first stage; reaching the diagnostic budget exits
normally while recording `curriculum_completed=false`. The reproduction runner
blocks the all-in-one workflow and independent network-training phases for this
pilot.
This experiment measures early learning, not final performance across all maps.

Two actors and a 50,000-transition replay limit reduce the initial resource
commitment. Exploration decays over 20,000 steps, and validation uses 20 fixed
greedy episodes every 100 training episodes. These are pilot hyperparameters;
the full configuration remains unchanged. A 20-episode success estimate is noisy.

Inspect `setup1_mapf/seed-42/training/validation.jsonl` for success and completion
fraction trends. `training_status.json` records device, measured steps/second,
cumulative wall time, and session seconds spent waiting for actors, learning,
and validating. Episode logs include intermediate timing. No validation records
means the pilot did not reach its first validation interval; it does not establish
learning quality. Use the timing split to choose the next optimization, then
repeat a bounded experiment under a new run ID. Do not infer a 10x implementation
speedup from a smaller training budget.

At the full 80-million-step ceiling, finishing one policy in 11 hours requires
about 2,020 joint steps/second; a 66-minute ceiling would require about 20,202.
These are budget arithmetic, not measured throughput or a verified comparison
with the original PANAMA. The inventory lists legacy files, but this checkout
does not contain `artifacts/legacy/`, so the original settings and timings still
need to be compared on the actual training machine.

The resolved configuration is `configs/panama_reproduction.toml`.

| Stage | Map | Agents | Episode cap | Minimum episodes | Graduation |
|---:|---|---:|---:|---:|---:|
| 0 | random-32-32-10 | 2 | 200 | 5,000 | 90% |
| 1 | random-32-32-10 | 4 | 200 | 5,000 | 90% |
| 2 | random-32-32-10 | 6 | 200 | 5,000 | 90% |
| 3 | random-32-32-20 | 6 | 200 | 5,000 | 90% |
| 4 | random-32-32-20 | 8 | 200 | 5,000 | 90% |
| 5 | random-64-64-10 | 8 | 400 | 5,000 | 90% |
| 6 | random-64-64-10 | 12 | 400 | 5,000 | 90% |
| 7 | random-64-64-20 | 12 | 400 | 5,000 | 100% |

Training uses the PANAMA reward coefficients, Double DQN, prioritized replay,
16 actor processes, validation every 1,000 episodes over 200 greedy
episodes, and an 80-million joint-environment-step ceiling per trained policy.
The three independent training seeds are 42, 43, and 44. Setup 3 is not trained:
it reuses the matching setup-1 policy so its MAPF decisions remain the controlled
baseline.

A stage that reaches its maximum episode count without meeting its graduation
threshold stops the reproduction. It is not silently advanced. Likewise, the
runner refuses to evaluate a model whose `training_status.json` says that the
curriculum was not completed.

## Radio calibration

The PANAMA paper publishes the radio link budget and -8.47 dB blackout threshold,
but not enough deployment coordinates to reconstruct its exact SINR raster. The
calibrated fixture therefore records the additional assumptions explicitly:

- 10 metres per MovingAI cell;
- a standard first-tier seven-site, 21-sector terrestrial cluster;
- a 9 dB aggregate interference margin for omitted co-channel tiers;
- the paper's terrestrial transmit power, bandwidth, carrier, antenna, shadowing,
  noise, and blackout threshold remain unchanged;
- the aerial model uses the AERIAL suburban parameters, a 90 dB admissible path
  loss, and a 20 m movement limit per simulation step.

Before compute starts, `scripts/calibrate_radio.py` checks every traversable map
cell. It requires non-degenerate terrestrial blackout regions on every map,
preserves the paper threshold, and requires partial UAV coverage on both 64x64
maps. The resulting machine-readable calibration is saved in the run directory.
These assumptions define this reproduction; they must not be changed after a run
has started.

## Manual run sequence

Install the project and run the checks once:

```bash
python3 -m pip install -e .
PYTHONPATH=src python3 -m unittest discover -s tests -v
```

Choose one stable run ID and use it for every command:

```bash
python3 scripts/run_panama_reproduction.py --phase preflight --run-id panama-r1
python3 scripts/run_panama_reproduction.py --phase train-mapf --run-id panama-r1
python3 scripts/run_panama_reproduction.py --phase train-network --run-id panama-r1
python3 scripts/run_panama_reproduction.py --phase evaluate --run-id panama-r1
python3 scripts/run_panama_reproduction.py --phase report --run-id panama-r1
```

The reward/replay definition is experiment schema version 3. It applies the
paper's potential reward exactly as
`gamma * Phi(s_next) - Phi(s)`, with
`Phi(s) = -distance_improvement * A*_distance(s, goal)`. An individual
transition becomes terminal at first goal arrival. Completed agents remain
physical obstacles at their goals, are forced to hold position, receive zero
subsequent reward, and are excluded from replay and network service. Do not reuse
a run ID containing schema-v2 checkpoints; the runner rejects that mixture and
requires training from the beginning.

Setup 1 still calculates the terrestrial radio field for matched telemetry, but
it neither observes that field nor receives the network reward. Full coverage
therefore cannot directly reward a setup-1 agent for staying still. The previous
shared replay did contain post-completion hold transitions; schema v3 removes
that source of a learned hold preference.

The first training phase is the PANAMA/MAPF reproduction gate. Inspect its three
validation logs and `training_status.json` files before spending compute on the
network-aware policies. Repeating a command with the same run ID safely resumes
it. To print every planned command without creating data or starting training:

```bash
python3 scripts/run_panama_reproduction.py --phase all --run-id panama-r1 --dry-run
```

For an incremental first attempt, train one configured seed and then return for
the other two without changing the run ID:

```bash
python3 scripts/run_panama_reproduction.py --phase train-mapf --training-seed 42 --run-id panama-r1
```

After the MAPF gate is trusted, the whole workflow can also be launched with:

```bash
python3 scripts/run_panama_reproduction.py --phase all --run-id panama-r1
```

The configured maximum is nine training jobs (three policies by three seeds),
or 720 million joint environment steps. Jobs run sequentially and each job uses
16 actors. Evaluation contains 6,000 paired episodes: four setups, three seeds,
four maps, 25 scenarios per map, and five agent counts. Missing held-out scenario
corpora are generated deterministically during preflight.

## Outputs and interpretation

Outputs are written under `artifacts/runs/<run-id>/`. The final report includes:

- overall and per-map aggregate CSV files with seed-cluster bootstrap intervals;
- paired setup differences for success, completion, PAR-2, blackout rate, link
  quality, outage-entry rate, A*-normalized makespan and sum-of-costs, agent
  movement, and UAV movement;
- explicit hypothesis checks for the expected four-setup tradeoffs in
  `comparison_expectations.csv`;
- validation-progress CSV and plots that show whether those metrics improve
  during training;
- raw episode records and compressed step telemetry;
- movement, selected action, reward, collision, connectivity, serving node,
  blackout-streak, and UAV trajectory data;
- a radio calibration JSON file and resolved experiment manifest.

The primary interpretation is MAPF non-inferiority together with a reduction in
blackout agent-steps per 1,000 unfinished-agent service steps. An agent leaves the
service population immediately on first goal arrival: the UAV no longer targets
it, it receives no network penalty, and its later radio state is excluded from
service percentages. Raw physical link telemetry is still retained. Absolute
blackout totals are kept for comparison with the PANAMA figures, while the
normalized rate prevents longer episodes or larger agent counts from looking
worse merely because they contain more exposure time.
