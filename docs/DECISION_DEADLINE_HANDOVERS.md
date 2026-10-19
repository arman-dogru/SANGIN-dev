# Decision deadline and satellite-handover inference

This study retains the qualified frozen Clean PANAMA model, its observations,
rewards, collision dynamics and four stages. It reuses the 200 held-out cases
from `leo-baseline-20261019-02`: 50 per stage, identical seeds, starts and goals.
Every episode still has at most 250 one-second robot steps and requires all
agents to occupy their goals simultaneously. There is no further training.

## A fixed 100 ms decision phase

At cycle start \(r_k=k\Delta\), where \(\Delta=1\) second, robot reports are
generated from the current grid state. Transport events are processed through
\(d_k=r_k+B\), where \(B=0.100\) seconds, before assembling the next observation:

\[
o_{i,k}=h\bigl(x_{i,k},C_i(d_k)\bigr),\qquad
a_{i,k}=\arg\max_a Q_\theta(o_{i,k},a).
\]

Only complete messages delivered by \(d_k\) can enter the receiver cache
\(C_i\). An update generated at \(r_k\) that arrives after the deadline cannot
change that decision. It can update a later decision's cache, provided its
timestamp/version is newer. Robots continue acting from their available cache;
no wait for a missing packet, local A* reconnection or recovery controller is
introduced. The goal, local sensing, self-position and truth collision handling
remain available. The policy parameters \(\theta\) are unchanged.

The 100 ms phase is inside the existing one-second control cycle and does not
add robot steps or accumulate another 100 ms onto every cycle. The grid model
does not resolve continuous subcell motion during this phase. All conditions,
including Perfect, use the same phase and action cadence. Communication uses
virtual event time; there are no communication sleeps. Initial mission briefing
remains fresh and is distinguished from subsequent response opportunities.

Meeting the deadline does not reset information age. If an update was generated
at \(g\), its age at the decision remains \(d_k-g\). A current-cycle update
therefore ordinarily has 100 ms of source age. Response deadline misses and
staleness of underlying peer-source reports are logged separately. Unselected
communication inputs are ideal fresh controls, timestamped at the decision.

The optional `decision_deadline_seconds` argument of `evaluation.run_episode`
defaults to zero. Training configuration and the original zero-deadline task
behavior remain unchanged. An explicit inference protocol version and source
hashes identify the new timing convention.

## Satellite-change ablation

The archived geometry, propagation, shared capacity, framing, reports and
resource reconfiguration remain fixed. Derived timelines preserve all geometry
and rate arrays byte-for-byte and record their parent timeline hash. They
distinguish actual satellite changes from initial attachment and same-satellite
resource reconfiguration.

| Condition | Satellite-change interruption | Other transport |
| --- | --- | --- |
| Perfect | None | Immediate reference |
| UAV-local control | Satellite events do not carry mission traffic | Physical UAV access |
| Handovers off | Counterfactual instantaneous change | Physical cloud route, regular resource reconfiguration retained |
| Handovers on | Archived assumed handshake window, approximately 50 ms | Same physical cloud route |
| 10 s stress | At least 10 s of service interruption at each actual satellite change | Same physical cloud route |
| 20 s stress | At least 20 s of service interruption at each actual satellite change | Same physical cloud route |

Switching interruptions off does not stop satellite motion or freeze an old
satellite assignment. It removes only the actual satellite-change service gap.
Regular same-satellite reconfiguration, initial setup, visibility restrictions,
frame guards, propagation and queueing are retained. Attachment events remain
logged with an explicit `interruption_applied` flag.

The 10/20-second durations are artificial service-outage stress assumptions,
not measured LEO handshake durations. Their starts follow actual satellite
changes in the archived timeline; there are no per-agent random reservation
windows. Overlapping outages are unioned rather than charged twice. Closely
spaced changes can therefore produce a continuous gap longer than 20 seconds.
Periodic replay handles intervals that cross a timeline seam. Scheduled windows
and actually encountered exposure are retained; episodes are never extended to
manufacture an exposure. UAV-local exchange continues during satellite outages.

Each physical condition is evaluated with A* guidance only, intentions only,
priorities only, and all three transported through the selected route. There
are 21 unique conditions, including the shared Perfect reference, for **4,200
episode executions**. All use a 100 ms decision budget and one frozen model.

Only the selected information fields generate remote requests; unselected
fields are ideal fresh observation controls. Transporting all three therefore
has a larger message workload than transporting one field. The causal handover
comparison pairs on/off within the same input selection and workload definition.

## Verification and records

Tests cover arrivals at 99/100/101 ms, preserved task transitions and rewards,
unchanged control-step counts, continuing actions while updates are late,
handovers off preserving regular reconfiguration and geometry, unioned stress
windows, and local access continuing through a satellite outage. Existing
transport conservation, late-version rejection and replay-resume checks remain.

The suite freezes code, model, map, original and derived timelines, configuration,
case bank and hashes in its run directory. Four Python workers evaluate
independent cases using batched agent inference. A completed run cannot be
resumed in a way that overwrites its measured runtime or completion timestamp.

Each compressed replay records decision times, source timestamps, response
deadline misses, underlying source age, model version, positions, queues,
handshake events and actual interruption application. Summary CSVs include
success, successful makespan, failure-aware PAR-2 (500 for a failed 250-step
case), completion fraction, collision attempts, UAV travel, deadline misses and
queue exposure. Paired bootstrap comparisons are reported against both Perfect
and the matching handovers-off condition. They characterize held-out case
variability for one trained seed, not variation over training seeds.

```powershell
.venv/Scripts/python.exe scripts/run_deadline_inference.py --run-id YOUR_NEW_RUN_ID
.venv/Scripts/python.exe scripts/plot_deadline_inference.py --root output/inference/YOUR_NEW_RUN_ID
```

The report verifies all 4,200 case identities, frozen policy/source hashes,
100 ms decision phases, metric aggregates and sampled replay records. Perfect
must reproduce the previous perfect-reference outcomes, and UAV-local robot
outcomes must match Perfect. Plots label stages only, use 0–100% success axes,
separate successful makespan from failure-aware metrics, and explicitly identify
the longer artificial interruptions. No recorded result is extended.
