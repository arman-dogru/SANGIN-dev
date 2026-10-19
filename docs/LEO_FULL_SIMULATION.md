# Library-backed LEO transport and extended learning study

Implementation: 9 October 2026. This document supersedes the old transport description for the new run only. Earlier measured results and frozen implementations remain intact.

## Scope and route

Ground robot → UAV → one serving LEO → ground gateway → cloud, and the reverse direction. There are two space legs, but no inter-satellite links or multi-satellite routing. The satellite backhaul is an equivalent transparent/bent-pipe link: its rate is the slower space leg and its propagation is the sum of both ranges. Separate access and satellite uplink/downlink queues share capacity across robots. Local UAV exchange can continue during backhaul interruptions.

This is a complete implementation of the defined orbital, link-budget and queued-transport experiment. It is not a reconstruction of proprietary Starlink RF/MAC, TCP congestion control or operational ground infrastructure. There is no public dataset identifying the actual serving satellite/beam/resource grant for this mission.

## Libraries and datasets

| Source | Used for | Evidence category |
| --- | --- | --- |
| [CelesTrak GP/OMM](https://celestrak.org/NORAD/documentation/gp-data-formats.php) | Actual Starlink element records, catalog IDs and epochs | Archived orbital data |
| [Pinned CelesTrak mirror](https://raw.githubusercontent.com/satvisorcom/satvisor-data/3c90be864dc8b3b8899a3cc3477957ae1e61564c/celestrak/json/starlink.json) | Byte-identical retained source after direct source timeout | Archived source mirror; SHA-256 in manifest |
| [Skyfield](https://rhodesmill.org/skyfield/earth-satellites.html), version 1.55; [SGP4](https://pypi.org/project/sgp4/), version 2.27 | Propagation, time scales, Earth rotation, ITRS position and velocity | Library-derived geometry |
| [ITU-Rpy](https://itu-rpy.readthedocs.io/en/latest/apidoc/itur.html), version 0.4.0 | P.618 atmospheric prediction with rain, cloud, gas and scintillation contributions; bundled ITU climatological maps | Standards-based statistical prediction |
| [SimPy](https://simpy.readthedocs.io/en/stable/api_reference/simpy.core.html), version 4.1.1 | Event timing and ordered execution without wall-clock sleeps | Discrete-event engine |
| [SATPIPE, INFOCOM 2025](https://xyzhang.ucsd.edu/papers/Ding.Zhao_INFOCOM25_SatPipe.pdf) | Measurement-informed 15 s scheduling interval and 50 ms service interruption | Published measurement basis, applied as a stated simulation assumption |
| [Starlink One-way Delay, ACM LEONET 2025](https://zenodo.org/records/16275284) | Separate directional packet-delay distributions for empirical comparison | Karlstad measurements; not Mont-Tremblant data |
| [MovingAI](https://movingai.com/benchmarks/mapf/index.html) | Retained `random-32-32-10.map` task map | Benchmark environment |

The orbital source SHA-256 is `b41fb2032d0ad72744e4234804fa66928f5e26445e8950764cce8789f35d8224`. The simulated geometry starts at **2026-08-31 00:00 UTC**, close to the archived elements; this is historical replay, not an October orbit prediction. Elements older than three days or outside the assumed 350–700 km altitude envelope are excluded. This envelope is a usability proxy, not proof of operational service. All 10,606 retained candidates are propagated; visibility requires the UAV and assumed gateway to see the same satellite.

The paired OWD recording has 187,624 uplink and 187,745 downlink samples over approximately 50 seconds. Mean packet OWD is 30.45 / 25.83 ms, and the 95th percentiles are 42.83 / 31.37 ms. Source hashes, direction, original nanosecond timestamps and archive members remain in `data/leo/starlink_owd/manifest.json`. Sequence gaps are not declared packet loss. Delay spikes are not declared observed handovers. These recordings are plotted independently: the main orbital simulation does **not** add recorded end-to-end delay on top of its modeled propagation, queues or interruptions.

## Geometry and link budget

The UAV terminal is at 46.2°N, 74.6°W, 440 m above sea level (an assumed 20 m above the 420 m site). The ground gateway is an assumed position at 45.3°N, 74.6°W and 300 m elevation; it is not a known provider gateway. The UAV mask is 25° and gateway mask 10°. Skyfield handles the Earth-fixed frame and velocity, using its bundled UT1 timescale; polar motion is zero. Grid-scale UAV motion is neglected for satellite geometry because the mission spans tens of metres against hundreds of kilometres of slant range. Robot-access service rates are allocated link budgets, not forest ray tracing or antenna pointing dynamics.

For endpoint Earth-fixed position x and satellite position s:

\[
\rho=\|s-x\|,\quad e=\arcsin\left(\frac{(s-x)\cdot\hat u}{\rho}\right),\quad
\dot\rho=\frac{(s-x)\cdot(v_s-v_x)}{\rho},\quad f_D=-\frac{f_c\dot\rho}{c}.
\]

Skyfield supplies the states and Earth rotation; the range/elevation/Doppler equations are geometric quantities. Doppler is recorded for both carriers. Ideal frequency compensation is assumed; there is no unsupported conversion of Doppler into packet loss.

The retained manuscript's free-space and achievable-rate formulation is used with a more explicit RF budget:

\[
L_{FS}=20\log_{10}(4\pi f_c\rho/c),\quad
\left(C/N\right)_{dB}=EIRP+G/T-L_{FS}-A_{ITU}-L_{impl}-10\log_{10}(k_B)-10\log_{10}(B),
\]
\[
R_{bound}=\eta B\log_2(1+10^{(C/N)_{dB}/10}),\quad
C_{backhaul}=\min(C_{allocated},R_{UAV},R_{gateway}).
\]

`A_ITU` comes from the library, not a locally implemented propagation model. It is the attenuation exceeded for 1% of an average year, evaluated against elevation. This fixed statistical design quantile is **not** an instantaneous rain time series, sampled weather, or an asserted 1% random packet-drop process. ITU contribution curves are interpolated over 10–90°. The implementation derives an engineering Shannon rate bound, not DVB-S2/Starlink MCS or measured throughput.

| Assumption | Default |
| --- | --- |
| Uplink / downlink carrier | 14.25 / 11.7 GHz |
| RF bandwidth | 20 / 100 MHz |
| Terminal / satellite EIRP | 35 / 30 dBW |
| Satellite / terminal receive G/T | −5 / +5 dB/K |
| Antenna diameter | 0.3 m |
| Implementation loss | 3 dB |
| Shannon efficiency | 0.5 |
| Allocated satellite uplink/downlink | 10 / 50 Mbps |
| Allocated robot-access uplink/downlink | 50 / 50 Mbps |
| Gateway → cloud one-way ground delay | 10 ms |

These values are configurable assumptions, not measured UAV or Starlink terminal specifications. In the current allocation, the configured Mbps ceilings often bind before the RF bound. The radio calculation therefore does not justify claiming those particular allocated rates are observed.

One-way space propagation is `(rho_UAV + rho_gateway)/c`; one-way cloud transit also includes the ground delay. An RTT requires both directions; the two space legs in a one-way path must not be mislabeled an RTT.

## Attachments, individual handshakes and regular service

At each 15-second boundary the simulated controller chooses the highest-elevation satellite visible to both endpoints. If visibility ends earlier, it reattaches immediately. A scheduling boundary with the same satellite is recorded as **resource reconfiguration**, not a satellite change. Both reserve a 50 ms service interruption. The six-hour timeline contains 1,440 scheduling events and 796 satellite changes after initial attachment, giving an approximate 27.1 s interval between changes. The visibility-selected policy is our assumption; SATPIPE does not provide these exact attachment decisions for Mont-Tremblant.

The assumed control protocol logs synchronization (5 ms), request (64 B uplink), grant (128 B downlink), completion (64 B uplink), ACK (128 B downlink), two 5 ms controller processing intervals, and a settling interval if needed to fill the 50 ms reservation. Each packet has a serialization and propagation time. These are explicit reserved control-plane events, not user payload counted a second time. The protocol itself is not measured Starlink signaling. Data is buffered during the reserved interval and resumes afterward, with no communication-triggered robot stopping.

SimPy executes all timestamped events. There are no communication sleeps. Per-agent FIFO queues receive equal round-robin **service chunks**, not unlimited parallel per-agent capacity. Chunk size is 256 KiB; this is computational aggregation of ordinary packets, not a 256 KiB IP MTU. The service budget includes 48 B overhead per 1,500 B of aggregate payload. Satellite service uses 20 ms frames, with the final 5% reserved for control/guard airtime. These regular framing values are experimental assumptions, not a provider scheduler. Other agents can transmit between chunks of a large model. No optimizer or priority allocation is secretly included.

For payload B bytes, service progresses by integrating the available capacity:

\[
8B=\int_{t_{start}}^{t_{finish}} C_h(t)\,a_h(t)\,dt,
\]

where `a_h(t)=0` during interruptions and guard intervals. Queues, serializing bytes, complete-message propagation and delivery are separate. Forwarding between logical access/backhaul hops is complete-message store-and-forward; it does not claim packet pipelining or TCP behavior. Payload and overhead counts remain distinct. Reassembly/deployment is atomic: no partial model becomes an acting policy.

The six-hour archived window is explicitly cycled for long learning runs. Orbital epochs are not extrapolated by simulated training days. Replay-cycle IDs and each boundary's attachment event are logged. This permits a reproducible repeated physical-transport exposure distribution; it is not a continuous multi-day constellation forecast. No visibility gap was found in this particular archived window; outages are not manufactured to increase effect size.

## Learning experiment and interpretation

`configs/leo_learning.toml` selects two freshly initialized seed-42 arms: **Perfect communication** and **Full LEO upload + deployment**. One CUDA learner runs at a time, with an allocation of 12 hours per arm including initialization, validation and checkpoints; it can finish earlier on qualification. The 24-hour ceiling is an allocation, not an estimated time to reach 95%. The selected fast-pilot learning rate 0.001, gamma 0.90, epsilon scale 20,000 and replay capacity 50,000 are disclosed; these are not nominal paper hyperparameters. Architecture, observations, task rewards and physical task transitions are retained.

The four phases are 2, 4, 6, 8 agents on the fixed map, with 250 steps per episode. Validation is greedy, 200 cases every 250 episodes after 500 training episodes, and graduation requires at least 95%. Exhaustion preserves an explicitly partial result; no graduation or success curve is forced.

Mission guidance, intentions and priorities remain fresh during these learning arms. This isolates transport of experience uploads and full-model deployments. The learner only receives complete delivered experiences; it can use a subset of agents and existing replay. Each robot acts with its last complete deployed model while uploads and snapshots are pending. Publication remains every 16 generated joint steps. A frozen-policy mission study can then vary guidance/intentions/priorities separately; the extended controller does not launch one automatically or promote an unqualified baseline.

Measured latency must distinguish small experiences from roughly 6.59 MB uncompressed model snapshots. The main configuration sends the common model across the backhaul once, then distributes complete copies from the UAV over the shared local link. Each robot installs independently after full receipt; no robot acts with partial layers. This removes redundant satellite copies, not actual transmission latency. The first per-agent satellite-unicast workload remains under `output/leo/leo-full-20261009-01`; it measured about 19.7 s model age at the largest stage. The final shared-relay workload is under `output/leo/leo-full-fanout-20261009-01`:

| Stage | Mean experience delivery | 95th percentile experience delivery | Mean complete model delivery |
| --- | --- | --- | --- |
| 1 | 25.2 ms | 68.3 ms | 3.57 s |
| 2 | 30.5 ms | 73.9 ms | 5.74 s |
| 3 | 35.9 ms | 74.4 ms | 7.91 s |
| 4 | 41.2 ms | 79.4 ms | 10.09 s |

These are actual 250-step fixed-payload transport measurements with interruptions enabled. A multi-second snapshot age is not propagation delay. The workload benchmark keeps weights fixed and has no learned mission-success outcome. Its figures must not be presented as learning or navigation results.

## Files and reproduction

```powershell
.\.venv\Scripts\python.exe -m pip install -e ".[leo,dev]"
.\.venv\Scripts\python.exe scripts\build_leo_timeline.py
.\.venv\Scripts\python.exe scripts\benchmark_leo_transport.py --config configs/leo_learning.toml --timeline data/leo/tremblant_full.npz --output output/leo/YOUR_NEW_BENCHMARK_ID
.\.venv\Scripts\python.exe scripts\report_leo_full.py --output output/leo/YOUR_NEW_BENCHMARK_ID
.\.venv\Scripts\python.exe scripts\run_leo_study.py --run-id YOUR_NEW_RUN_ID
.\.venv\Scripts\python.exe scripts\report_leo_learning.py --root output/leo-learning/YOUR_NEW_RUN_ID
```

The controller freezes code, map, orbital timeline, complete configuration and library versions, and verifies matched initialization hashes. Every message retains source time, version and immutable encoded payload. Communication schema 4 prevents silently resuming an old transport implementation. SimPy pending events are serialized as a deterministic calendar and reconstructed on restore. Tests cover conservation, partial-message withholding, round-robin fairness, frame/interruption integration, replay seams, local UAV availability, exact continuation and the unchanged phase gate.

`leo_motion.html` is self-contained and opens directly in a browser. It shows library-propagated satellite motion, current attachment, link range/elevation/Doppler/propagation, and the current control phase. **Next handshake** stops inside a 50 ms event so it can be inspected. Static PNGs show RF geometry, protocol steps, delivery ECDFs, queue timelines and latency components. Training plots use recorded episodes and 200-case validation dots, with success axes fixed at 0–100%. No recorded result is extended or synthesized.
