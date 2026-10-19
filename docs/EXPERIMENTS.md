# UAV–PANAMA communication staleness protocol

## Retained task baseline

The starting point is commit 91f75e6 (0.1). The dual-stream DQN has three spatial channels (obstacles, nearby robots, asymmetric intentions), twelve vector features, and five actions. Rewards retain 0.1's goal, step, obstacle/robot collision, distance improvement, path conflict and hold terms. Its distance improvement reward is the original raw distance difference, not a newly introduced potential-based formulation. Task dynamics, rewards and collision resolution use truth. No communication penalty, stopping rule, recovery controller, imitation policy or routing restriction is added.

Only UAV communication is modeled. Semantic task offloading is deferred. Physical UAV geometry is retained; its movement controller receives successfully delivered robot reports at the UAV. Its radio geometry is used to display coverage, not to impose new SNR-based observations, rewards or packet losses. Message service in this first study uses shared access capacities rather than a calibrated location-dependent fading/packet-loss model.

The fixed map is maps/random-32-32-10.map. Four phases use 2, 4, 6 and 8 agents. Every training, validation and inference episode is capped at 250 joint steps. All robots must occupy their goals simultaneously; earlier visits are logged separately and do not establish mission success.

Greedy validation uses 200 deterministic validation cases every 250 completed training episodes, beginning at episode 500. A phase advances only with at least 190 successes. Validation cases are separate from held-out inference cases. Incomplete validation cannot graduate a phase. Phase or time-budget exhaustion remains partial.

## Virtual-time transport

One robot step is one second by default. Floating-point event timestamps retain subsecond precision. The simulator never sleeps for communication. Access uplink/downlink and satellite uplink/downlink each have independent byte-service budgets, shared by agents in one mission. Each link transmits one complete message at a time, uses FIFO within each agent's ready queue, and selects agents by equal round-robin order between messages. Equal turns are not an optimized bandwidth allocation; message sizes may differ.

Reservation buffering occurs before a packet becomes ready for link service. A later message in the same agent/type flow waits behind a reserved message; updates cannot bypass the hold. Different flows and variable physical/trace delays can still arrive out of order. Receiver caches and deployed model versions reject late older data. No message is intentionally dropped; checkpoint/event counters distinguish generated, delivered and pending traffic. Episode completion does not drain queues artificially.

Packets encode complete values with pickle protocol 5, disabling reference memoization for stable encoded size after resume. The encoded payload and timestamp/version/agent envelope both count toward service bytes. Snapshots encode full NumPy weight arrays, shape/dtype metadata and phase tags; transmissions are per-agent unicast. The wire format is a simulation accounting format, not a proposed production security protocol. Only repository-generated artifacts should be loaded.

Transmission time equals encoded bytes × 8 / link capacity. Queue delay, serialization/transmission, propagation, interruption and controlled additional delay are logged separately. Model tensors are installed only after the entire snapshot arrives. There is no partial-weight inference.

## Receiver information and mission routes

The initial mission briefing is fresh at simulated time zero. Robots retain their goals, local obstacle sensing, local robot sensing and self-position throughout. Communication inputs are separate caches:

- Task: an absolute A* route and its reported distance. Reached waypoints are consumed. Remaining waypoints are expressed relative to the current robot position using 0.1's five two-coordinate features. If the robot leaves that route, it continues using the cached absolute waypoints; no fresh local A* is substituted.
- Intentions: the last received absolute peer path segments, including communicated completion flags.
- Priorities: the last received values used for the asymmetric intention comparison, including the receiver's communicated priority.

Remote A* processing uses the reported position and known goal. Truth A* still updates internally for physical task rewards and collision semantics, and does not refresh an intervened observation cache. Monotonic source timestamps and versions prevent rollback. Fresh fields in an isolated intervention are updated independently as perfect-information controls; only selected communication inputs are aged.

UAV edge mission processing follows robot → UAV processing → robot. Cloud mission processing follows robot → UAV → satellite → cloud processing → satellite → UAV → robot. Peer reports available at the UAV are bundled for processing; the processor does not silently read current global peer positions. Local UAV positioning consumes access reports even while backhaul forwarding is interrupted. Processing time is configurable and defaults to zero.

The learner is in the cloud in both routes. During learning-delay experiments, all mission-information observations remain fresh; only experience and model transport is delayed. Frozen inference experiments do not update the learner.

Information age is receiver time minus the source timestamp of the received information. For peer intention/priority bundles the main age is the oldest included peer report; per-peer ages are also recorded. It includes end-to-end service delay and sampling between updates. Access report age at the UAV is logged independently. Full cached guidance and per-agent ages are retained in episode traces.

## Physical and controlled profiles

SATPIPE reports an approximately 15-second satellite scheduling period and a roughly 50 ms handover interruption. These motivate the default reassignment/handshake windows; they do not establish measured parameters for this UAV deployment. See [SATPIPE, INFOCOM 2025](https://xyzhang.ucsd.edu/papers/Ding.Zhao_INFOCOM25_SatPipe.pdf).

| Parameter | Default | Provenance |
|---|---:|---|
| Satellite scheduling interval | 15 s | SATPIPE-informed approximation |
| Handshake/forwarding interruption | 50 ms | SATPIPE-informed approximation |
| One-way backhaul propagation | 25 ms | Configurable simulation assumption |
| Satellite uplink/downlink | 10 / 50 Mbps | Configurable simulation assumption |
| UAV access uplink/downlink | 50 / 50 Mbps | Configurable simulation assumption |

Satellite assignment index changes at each configured scheduling boundary. Forwarding buffers during interruption and resumes afterward. A transmission spanning a boundary is paused for the interruption; access exchange continues. The model does not invent TCP congestion-window recovery or infer packet loss.

The controlled profile schedules one or two seeded service-reservation windows per agent per episode, independently of policy actions. Each defaults to two steps in duration. Messages generated or released for deployment during an active window receive the configured additional delay once, then become ready for service. Delays sweep 1, 2, 5, 10 and 20 steps. The flow remains FIFO while buffered, so newer updates cannot erase the intended multi-step stale exposure before the held traffic resumes. These are contention interventions, not measured handover lengths. Windows can fall after early completion, producing no exposure. Episodes are not extended to force exposure.

A one-second action cadence may make a 50 ms interruption produce no change in policy actions or mission results, even though its subsecond traffic delay is recorded. Identical outcomes are a valid measured finding. The controlled profile supplies independent multi-step severity interventions without mislabeling them as measured physical interruptions.

## Imported one-way delay

The [Starlink OWD dataset](https://zenodo.org/records/16275284) provides separate uplink/downlink files with sequence number, transmit timestamp and one-way delay. Source timestamps and delays are in nanoseconds. Sequence gaps can reflect timestamp readout failures and cannot establish packet loss.

Download/extract a desired source file separately; the simulator does not automatically download the 5.9 GB archive:

```powershell
python -m panama_uav import-trace --input traces/example_ul --output traces/uplink.npz --direction uplink --unit ns --start 0 --end 300
python -m panama_uav import-trace --input traces/example_dl --output traces/downlink.npz --direction downlink --unit ns --start 0 --end 300
```

Start/end are source timestamp bounds in seconds. Set uplink_trace and downlink_trace under [communication] in a copied project configuration. The imported file preserves direction, original timestamps and sequence strings, units, source SHA-256 and selected segment. Its relative clock starts at the segment's first sample. The latest preceding measured delay is used; exceeding the segment raises an error rather than silently looping.

An imported delay replaces the entire corresponding satellite-backhaul hop, including modeled satellite transmission, propagation, queueing and handshake delay. UAV access remains a separate modeled hop. Trace spikes never become inferred confirmed handovers. Configured handover windows remain explicit scheduled model events, and modeled satellite interruption is bypassed for an imported hop. Trace provenance is included in the run manifest. Explicit handover start/end and assignment events are recorded even when there is no queued traffic.

## Frozen-policy inference study

Train clean first and freeze its qualified final learner weights. The full suite rejects an unqualified model. A diagnostic override exists for plumbing checks and labels every record.

Fifty deterministic held-out cases per agent count are paired across all interventions, with exactly the same starts, goals, goals known to robots, and reservation seeds. The case-bank JSON and hash are saved. Conditions are:

- One perfect zero-delay reference shared by both equivalent routes.
- Both routes × task only, intentions only, priorities only, all three × delays 1/2/5/10/20.
- Both routes × physical handover only, contention only, handover plus contention.

This is 47 conditions × 200 paired cases = 9,400 episodes. Inference timing is separate from the twelve-hour learning allocation. Individual treatment names can be selected with --conditions; perfect is always included. Physical contention uses the configured additional resource delay alongside actual shared-capacity serialization. Frozen model versions are constant and identify the final learner update, rather than suggesting online deployment occurred.

Summary records include paired bootstrap intervals for PAR-2 and success differences. Bootstrap resamples paired case identities separately at each agent count.

## Online learning transport study

Seed 42 and matched fresh model initializations are used in clean, uplink_delayed, downlink_delayed and combined arms. Initial weight hashes verify matching. One mission generates batched robot actions. The original Double DQN update, AdamW/AMSGrad optimizer, Huber loss, gradient clip 1, soft target update, PER settings and epsilon decay values are retained.

Every generated joint step creates one immutable complete experience per agent. Uplink-delayed arms send those tuples over robot access and satellite uplink queues. The learner sees only delivered tuples. One learning opportunity occurs per generated joint step, reusing received replay data when uploads are pending; it skips only if replay lacks a full batch.

All arms publish full snapshots every 16 generated joint steps. Downlink-delayed arms send them over satellite and access downlinks. Receivers keep acting with their deployed versions; a complete received model is applied before the next action. Late older versions cannot overwrite newer versions. New agents joining a curriculum phase receive the last fully published snapshot; existing agents retain their deployments. This phase-entry briefing is explicit.

Validation measures the current learner model greedily with fresh mission information and a fixed case set, identically across arms. It does not mix exploration or per-agent deployment lag into the graduation threshold. Replay resets at qualified phase changes as in 0.1. Experiences arriving from an earlier phase are counted as delivered, explicitly counted as discarded_previous_phase, and excluded from the new phase replay.

Generated joint steps, received tuples, updates, publications and wall-clock seconds have separate counters. Generated steps determine epsilon decay and publication timing even when uploads are delayed.

Each arm receives 10,800 wall-clock seconds including initialization and validation, reserving 60 seconds for checkpoint/shutdown. Checkpoint cost is counted; a very slow final filesystem write can exceed the reserved time and is visible in actual wall_seconds. A budget cannot interrupt a tensor update or filesystem write midway. Clean failure blocks full mission evaluation and is reported explicitly. The other learning arms retain their independent three-hour allocations and partial phase outcomes; comparison uses their common generated-step range. Optional physical-profile learning can be selected explicitly.

Checkpoints retain policy/target/optimizer, the entire PER tree and samples without truncation, replay sampling RNG, Python/NumPy/Torch/CUDA RNG, active environment and observations, cached guidance, receiver versions and actor weights, pending messages and transport clock, scheduled windows, counters, phase qualifications and elapsed allocation. Resume restores JSONL offsets to the checkpoint boundary, avoiding duplicate output after rollback. Ctrl+C is deferred to a completed joint-step or validation-step boundary. An interrupted validation remains pending and is retried on resume within the remaining wall budget. Checkpoints contain Python objects and require this implementation.

## Recorded data and plots

Outputs are under output/communication/<new-run-id>/.

| File | Content |
|---|---|
| <condition>/manifest.json | Config/schema, code hashes, map hash, initial weights and assumptions |
| <condition>/learning_steps.jsonl | Every joint step, received samples, opportunities/updates, model ages/lag, replay ages, queue bytes, actions, positions, UAV travel, wall progress |
| <condition>/transport.jsonl | Scheduled windows, realized exposures, encoded sizes, hop timings, delivery ages and traffic |
| <condition>/training.jsonl and .csv | Completed training episodes, phase/episode/step axes, success, PAR-2, completion and collisions |
| <condition>/validation.jsonl and .csv | Validation dots, coverage of all 200 cases, qualification inputs |
| <condition>/validation_cases.jsonl | Individual measured validation cases |
| <condition>/status.json | Explicit qualified or partial outcome and pending traffic |
| inference/held_out_cases.json | Paired seeds, starts, goals and map fingerprint |
| inference/<treatment>/episodes.jsonl and .csv | All measured inference episode metrics and realized exposure |
| inference/<treatment>/<case>.json.gz | Full robot/UAV trace, cached routes, ages, versions, queue timeline and transport events |
| inference/<treatment>/summary.json | Success, successful makespan, PAR-2, completion/collisions/travel and paired intervals |
| plots/ | PNG/PDF figures and plot/input manifest |
| replay.html and replay.json | Portable fresh/stale browser replay and its underlying measured records |

PAR-2 is actual makespan for success and 500 steps for failure (2 × 250). Successful makespan is null when no success is recorded; it is never substituted for failure-aware performance. Completion fraction counts current goal occupancy; first-visit completion is a separately named diagnostic.

Training plots show trailing success averages from recorded episodes and complete validation dots, separately by phase. Success axes are always 0–100%. Generated-step comparisons include the common measured range across available arms. Wall-clock progress and delivered-sample counts remain visible. Plotting does not extend curves or fill missing phases. Learning-step display may stride-sample recorded points for display; source JSONL contains every step. Unqualified smoke figures are transport diagnostics, not mission evidence.

## Acceptance checks

Run python -m pytest. Tests cover the frozen 0.1 golden trace, absolute guidance consumption and cache rollback, intervention isolation, truth-based rewards, simultaneous goals and step cap, received-report UAV control, shared-capacity service and byte conservation, edge exchange during satellite handshake, seeded windows and absent early exposure, directional trace import/replacement, immutable experience tuples, moving robots during upload/deployment delays, matched initialization, atomic snapshots, version monotonicity, exact checkpoint continuation, strict validation threshold, rejected legacy checkpoints and partial-budget gating.

The offline replay can be opened directly or served locally:

```powershell
python -m panama_uav replay --run-id stale-study-01 --agents 4 --mission-route cloud
python -m panama_uav serve-replay --path output/communication/stale-study-01/replay.html --port 8765
```

Then open http://127.0.0.1:8765/replay.html. Use the time slider and robot selector to compare recorded positions, cached absolute guidance, per-field age, model version, UAV coverage/altitude, scheduled handshakes and actual reservation windows.
