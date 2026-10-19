# Qualified-baseline mission-information inference

This is a separate study from experience-upload/model-deployment delay training.
The fully qualified Clean final model is frozen and evaluated greedily. There is
no learning, no experience-replay update and no model deployment during a case.

## Paired design

- Four stages use 2/4/6/8 robots, with a 250-step episode cap and simultaneous
  occupancy of all goals required for success.
- Fifty held-out cases per stage use seeds `50000000 + 10000*n + case`, distinct
  from the curriculum validation seeds. The same starts, goals and seeds are
  used for every condition. They are saved once in `held_out_cases.json`.
- A single perfect-communication reference is shared by all comparisons.
- Receiver-cache interventions delay A* task guidance only, intentions only,
  priorities only, or all three together. Local obstacle/robot sensing and
  self-position stay fresh; physical collision resolution uses truth.
- Cached A* guidance is an absolute route with its reported distance. Reached
  waypoints are consumed; the receiver does not recalculate A* while waiting.
  Intentions retain their last absolute path segments. Received priorities are
  used for the asymmetric intention observation. Late updates cannot roll back
  cache timestamps or versions.

## Separate delay profiles

Controlled tests sweep additional delays of 1, 2, 5, 10 and 20 robot steps.
The inherited seeded schedule reserves one or two two-step service windows per
robot; the scheduled update is held for the selected delay and newer updates
remain FIFO behind it. This is controlled contention, not a claim about measured
handover durations. Scheduled and actually experienced exposures are recorded;
early completion is never extended to manufacture exposure.

The controlled profile bypasses link serialization, propagation and orbital
framing. Both configured processing times are zero in this run, so updates are
immediate outside the scheduled holds and their FIFO backlog. This is an
intermittent stale-information intervention, not a 1–20-step delay added to the
orbital transport. The controlled and orbital profiles are separate experiments,
not a single latency-severity ladder.

Orbital tests use the archived Skyfield/SGP4 geometry, ITU-R rate bounds, actual
message sizes, shared queues, framing, propagation and handshakes documented in
`LEO_FULL_SIMULATION.md`. They disable artificial contention. Each episode starts
at the retained 1,000-second timeline offset, identically across conditions;
this initial orbital phase is an assumption, not a random sample of all mission
start times.

Both profiles compare UAV-edge and cloud mission processing. Satellite traffic
is used only on the cloud route; UAV-local exchange remains available during
satellite handover. Ordinary UAV access transmission time can itself make a
cache stale. A comparison against perfect communication includes these normal
transport delays; it does not isolate the handover component alone.

### Decision timing and interpretation

Reports are generated at integer robot-step boundaries, and the next action is
chosen immediately using the cache available at that boundary. Delivery events
retain subsecond timestamps, but the robot does not wait inside its decision
step for a response. Thus a response taking 27 ms can still leave guidance one
robot step old at the next decision; it is not a 1,000 ms radio delay. With the
one-second control interval, subsecond latency changes can have identical
decision-time observations. Perfect communication supplies current-step inputs
and is therefore an idealized synchronous reference.

A stale absolute route can differ from a freshly planned route when the learned
action leaves that route. Consuming reached waypoints does not reconnect a
robot to the route through a new local A* search. Oscillation or failure in this
case measures the frozen policy's response to stale guidance under this
report/decision schedule. It must not be attributed solely to satellite
handover. Comparing the UAV-edge and cloud routes, and the input-specific
interventions, helps identify this distinction. The goal and local sensing
remain available throughout.

There are 49 unique conditions: one perfect reference, eight orbital conditions
(two routes times four input selections), and 40 controlled conditions (two
routes times four input selections times five severities). Each has 200 cases,
for 9,800 episode executions. Four independent Python processes evaluate cases
concurrently, with batched agent inference and one frozen policy per process.
Deterministic CUDA kernels are selected for reproducibility. Worker count changes
throughput, not simulated step duration or communication time.

## Records, audit and plots

Every case has measured JSONL/CSV outcomes and a compressed replay containing
positions, cached guidance, information age, model identity, UAV state and
transport events. Raw case files and the frozen code/model/data stay local.
The manifest retains their hashes and the complete configuration. Completed case
IDs support a restart without repeating already recorded cases.

Primary plots show success (0–100%) and successful-episode makespan at each
stage. Separate PAR-2 plots assign 500 steps to failed 250-step episodes so that
failed hard cases are not hidden by successful-only makespan. Summaries include
mean episode length, completion fraction, collision attempts, UAV travel,
paired changes against perfect communication and paired bootstrap intervals.
The successful-makespan difference among cases solved by both conditions is
also recorded. Fifty paired test cases characterize case variability for one
trained model; they do not establish variability across training seeds.

```powershell
.venv\Scripts\python.exe scripts/run_leo_inference.py --run-id YOUR_NEW_RUN_ID
.venv\Scripts\python.exe scripts/plot_leo_inference.py --root output/inference/leo-baseline-20261019-02
```

The trained baseline is accepted only after qualification in all phases. No
synthetic curves, modified successes, recovery controllers or radio-dependent
task rewards are introduced.

The completed `leo-baseline-20261019-02` comparison and its measured figures are
published in [the inference report](../output/results/leo-inference-20261019-02/README.md).
The earlier `leo-baseline-20261019-01` remains archived after a fractional-bit
service-loop stall; the replacement reran all cases after the numerical fix,
without carrying partial-run outcomes forward.
