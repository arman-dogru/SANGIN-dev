# Incremental training ladder

Run one rung at a time and inspect its report before starting the next. Every
budget below is a maximum joint-environment-step count per trained policy and
seed. Setups 1, 2, and 4 train policies; setup 3 reuses setup 1. Curriculum
graduation can finish a run well below its maximum.

| Rung | Initialization | Step cap | Seeds | Actors | Curriculum maps | Maximum trained agents | Evaluation |
|---|---|---:|---:|---:|---:|---:|---|
| 01 proof | retained PANAMA model | 12,000 | 1 | 4 | 1 | 4 | 25 random scenarios at 4 agents |
| 02 pilot | retained PANAMA model | 100,000 | 1 | 4 | 2 | 6 | 25 random scenarios at 4, 6, and 8 agents |
| 03 medium | from scratch | 1,000,000 | 1 | 8 | 4 | 8 | random and room corpora at 4, 8, and 16 agents |
| 04 preflight | from scratch | 10,000,000 | 2 | 12 | 8 | 12 | all corpora at 4, 8, 16, and 32 agents |
| 05 full | from scratch | 80,000,000 | 5 | 16 | 9 | 16 | all 125 scenarios at 4, 8, 16, 32, and 64 agents |

The pilot is intentionally warm-started to test the merged system cheaply. The
medium rung is the first meaningful test of learning from scratch. Do not treat
proof or pilot measurements as independent paper results.

Fixed scenario corpora currently exist only for random-32-10, room-32, and the
warehouse map. The added random-20, maze, random-64, and room-64 curriculum maps
still receive deterministic greedy validation with seeded random start/goal
pairs, but they are not part of the fixed-scenario report until matching scenario
files are added.

## Running a rung

Use a distinct run ID for each rung:

```bash
./scripts/run_ladder_stage.sh proof ladder-01-proof
./scripts/run_ladder_stage.sh pilot ladder-02-pilot
./scripts/run_ladder_stage.sh medium ladder-03-medium
./scripts/run_ladder_stage.sh preflight ladder-04-preflight
./scripts/run_ladder_stage.sh full ladder-05-full
```

Every command is resumable. Repeating the same command and run ID continues its
checkpoints and skips completed evaluation episodes.

## Promotion checklist

Before moving up one rung, verify:

- the final curriculum stage was reached rather than exhausting the global step
  cap in an early stage;
- greedy validation success and completion did not collapse at a map transition;
- evaluation success, PAR-2, completion, collisions, and network quality are
  plausible for every setup;
- learner losses remained finite and did not show sustained growth;
- every evaluation episode has its compressed telemetry file;
- the estimated runtime and disk use of the next rung are acceptable.

If a rung fails, resume it only when more steps are appropriate. If the failure
starts exactly at a new map, adjust that stage's minimum episodes or insert an
intermediate agent count instead of increasing the global budget blindly.

## Important radio preflight

The current physical scale is one metre per grid cell. On 32x32 maps this can
place the entire map inside the configured UAV coverage radius, producing zero
blackouts. Before using preflight or full results in a paper, validate the cell
size against the intended physical deployment or add a separately justified RF
stress configuration. Do not change the scale between compared setups within a
run.
