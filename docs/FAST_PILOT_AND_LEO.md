# Faster learning pilot and data-driven LEO transport

The stopped `comm-staleness-study-01` remains preserved. These are new experiments,
with fresh initializations and measured outputs. No results are extended or invented.

## Learning diagnostic, October 5

The original exponential exploration scale was 5,000,000 generated joint steps.
At 350,000 steps, epsilon was still about 0.939. Greedy validation was 0/200 at
each of four checks. The initial short screening also showed inflated action
values and poor goal progress; changing exploration alone was not sufficient.

The new pilots retain the 0.1 DQN architecture, observations, task rewards,
collision handling and simultaneous-goal success definition. They screen learning
rates 0.0001 and 0.0003 with exploration scales 5,000 and 20,000 steps at gamma
0.99. A separate bootstrap-stability screen uses gamma 0.90, exploration scale
20,000, and learning rates 0.0003 and 0.001. Epsilon still starts at 1 and ends
at 0.1. These are exponential scales, not steps until epsilon reaches its floor.

Each candidate uses seed 42 and the same initial weights, 40,000 joint steps,
the fixed 32×32 map and two agents. A common replay capacity of 50,000 avoids
multi-gigabyte checkpoint overhead and keeps recent samples. Batch size 64,
PER, AdamW, target tau 0.005, and publications every 16 steps remain unchanged.

Every 10,000 steps, a greedy check evaluates 30 *tuning* cases seeded from
8,000,042. These checks cannot graduate a phase and are separate from the
200-case production qualification and the final held-out mission cases. Source
copies and their hashes are frozen under each pilot's `code` directory.

At 40,000 joint steps, all four gamma-0.99 candidates scored 0/30. With gamma
0.90 and the 20,000-step exploration scale, learning rate 0.0003 scored 22/30
(73.3%), and 0.001 scored 26/30 (86.7%). The latter used 416 training episodes
and approximately 515 seconds, including its screening checks.

A separate diagnostic at seeds 7,000,042–7,000,241 scored 175/200 (87.5%) with
that frozen screening model. These cases are neither the tuning cases nor the
production qualification or final mission test cases. This result is **not
graduation**: it remains below 95% and the model had fewer than 500 training
episodes. The weaker automatic follow-up was stopped after screening completed;
all its screening artifacts remain preserved.

After screening, the chosen parameters are used in a **fresh** curriculum run.
The 2/4/6/8 phases still require at least 500 training episodes, validation every
250 episodes with 200 cases, and at least 95% success. All episodes stop by 250
steps. A three-hour allocation includes validation and checkpointing; budget
exhaustion is partial. A good screening score is not a qualified final model.

The fresh selected run is `fast-curriculum-20261005-01`, started at 12:49 pm
Toronto time on October 5, with its three-hour allocation ending around 3:49 pm.
Its configuration is `configs/fast_pilot.toml`. Hourly monitoring follows this
run; the old stopped communication comparison is not restarted.

Run directories are under `output/learning-pilots`. Regenerate measured plots:

```powershell
python scripts/report_learning_pilots.py
```

## Actual data and simulated geometry

Orbital elements come from CelesTrak OMM JSON, archived from a pinned mirror
revision because the origin was unavailable. The local manifest retains source
URL, revision, retrieval time, epochs, original bytes and SHA-256. The snapshot
contains 11,037 entries dated August 25–31, 2026. The geometry calculation uses
10,606 entries within three days of August 31 and with a modeled perigee of
350–700 km. This altitude filter is an operational-shell proxy, not confirmation
that each satellite serves customers.

**The simulation replays August 31 near the elements' epochs. It does not
propagate the old snapshot to October 5 or claim today's constellation.**
SGP4 uses the official Vallado propagator through `sgp4`. TEME coordinates are
rotated into ECEF using GMST; UTC approximates UT1, and polar motion is omitted.
WGS84 supplies the observer position and local vertical. Error samples are
excluded and counted.

The assumed mission site is 46.2° N, 74.6° W, near remote Mont-Tremblant, with
a 420 m antenna altitude above sea level. Its elevation mask is 25°. An
illustrative gateway at 45.3° N, 74.6° W, 300 m ASL uses a 10° mask; this is
**not a measured provider gateway**. The model does not include terrain,
foliage, weather, antenna tracking errors or inter-satellite routing.

On attachment, select the visible satellite with the highest elevation and
retain it until visibility ends. This is an explicit simulator selection rule,
not a reconstruction of Starlink's proprietary scheduler. One-second samples
resolve contact boundaries. Missing visibility buffers satellite traffic;
robot–UAV exchange continues.

For satellite position `r`, ECEF velocity `v`, observer position `o`, and local
vertical `u`, geometry uses:

```text
rho = ||r-o||
elevation = asin(((r-o)/rho) dot u)
range_rate = v dot ((r-o)/rho)
raw_Doppler = -carrier_frequency * range_rate / c
space_one_way = (rho_user + rho_gateway) / c
traffic_propagation = space_one_way + assumed_ground_delay
transmission = 8 * actual_encoded_bytes / capacity_bits_per_second
```

Ground delay is an assumed 10 ms one-way. Uplink/downlink frequencies are
14.25/11.7 GHz for Doppler telemetry. Ideal Doppler compensation is assumed;
raw Doppler is not converted into outages. Access capacities are 50/50 Mbps;
satellite capacities are 10/50 Mbps. These capacities are simulation assumptions.
Shared FIFO/round-robin queues conserve message bytes and separately record
transmission, queueing, propagation and interruption.

Each attachment models 5 ms synchronization, then individual request (64 B UL),
grant (128 B DL), complete (64 B UL) and ACK (128 B DL) packets. Transmission
uses the stated directional capacities, each packet incurs the two space-leg
delay, and the request/complete processing adds 5 ms each. Traffic is buffered
until completion. This protocol is assumed, not measured Starlink signaling.

The six-hour archived run has 172 satellite changes: roughly one per 126 s,
or about two in a 250-second mission. Mean handshake interruption is 28.8 ms.
The separate existing SATPIPE 15-second/50-ms scheduling benchmark remains a
measurement-informed sensitivity condition; it is not an orbit-derived contact
duration or a confirmed satellite identity change.

## Measured delay traces

The actual [LEONET one-way-delay dataset](https://zenodo.org/records/16275284)
was measured in Karlstad, Sweden, in April 2025. It is **not a local Québec
measurement**. The paired run `2025-04-11-15-16-16` supplies 187,624 uplink and
187,745 downlink measurements over approximately 50 seconds. Mean UL/DL delays
are 30.45/25.83 ms; 95th percentiles are 42.83/31.37 ms.

HTTP ranges extracted the original zipped members with ZIP CRC verification.
Manifests retain member and CSV hashes, directions, original nanosecond
timestamps and segment limits. The publisher's checksum for the entire 5.9 GB
archive is recorded but cannot be verified from partial downloads. The paired
files retain their common run-start origin. Neither missing sequence numbers
nor delay spikes are interpreted as confirmed loss or handovers. A trace is
never repeated, stretched, or extrapolated beyond its recording.

The paper's measurements use 150-byte UDP/IP probe packets under light load.
They establish packet latency, not bulk model-transfer time. A trace replaces
its modeled satellite-hop delay without adding orbital propagation or handover
delays again. Bulk model deployment with imported UDP traces is rejected;
use the capacity-based orbital model for multi-megabyte snapshots.

## Transport results versus policy results

`scripts/benchmark_leo_transport.py` simulates fixed, encoded experience/model
traffic for 250 seconds at 2/4/6/8 agents. It is a transport workload test,
not an inference success experiment. All snapshots use fixed seed-42 weights;
they are published every 16 steps and sent by per-agent unicast through both
satellite and access queues. The paired reference keeps geometry, capacities
and propagation identical but removes handshake interruption.

Mean model delivery ages are approximately 2.65, 3.71, 4.76 and 5.81 seconds.
The 8-agent maximum is about 9.53 seconds. These seconds largely come from
serialized full snapshots and the shared access link; they must not be
attributed solely to LEO handovers. The handshakes' incremental mean delay is
small in this workload. A latency spike does not establish a policy impact.

Measured CSV/JSONL, manifests and plots are under
`output/leo/tremblant-data-20261005-01`. Full mission comparisons remain gated
on a qualified clean model. No effect on mission success is promised in advance.

## Reproduce data acquisition and geometry

```powershell
python -m pip install "sgp4>=2.27"
python scripts/fetch_starlink_orbits.py
python scripts/fetch_starlink_delays.py --pair-index 0
python scripts/build_leo_timeline.py --start 2026-08-31T00:00:00+00:00
python scripts/benchmark_leo_transport.py --output output/leo/new-unique-run
```

For a different orbital snapshot, select a simulation start near its recorded
epochs. `configs/leo_tremblant.toml` selects the generated timeline in the
physical inference profile. Use a new run ID. The empirical trace and orbit
models are mutually exclusive to prevent double-counting. Checkpoints retain
the loaded orbital timeline and event cursor alongside existing transport state.

Sources: [SGP4 implementation](https://pypi.org/project/sgp4/),
[CelesTrak GP formats](https://celestrak.org/NORAD/documentation/gp-data-formats.php),
[LEONET dataset](https://zenodo.org/records/16275284),
[LEONET paper](https://diva-portal.org/smash/get/diva2%3A2013617/FULLTEXT01.pdf),
and [SATPIPE](https://xyzhang.ucsd.edu/papers/Ding.Zhao_INFOCOM25_SatPipe.pdf).
