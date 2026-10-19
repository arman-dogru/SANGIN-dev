# UAV PANAMA communication staleness study

## Engineering formulations and evidence

**Implementation audit dated 5 October 2026**

This guide explains the simulator as it is implemented: what the robots know, how messages become old, how satellite geometry is calculated, and which quantities come from measurements. It assumes engineering knowledge but no telecom background.

The study asks two separate questions. First, how does delayed mission information affect a frozen pathfinding policy? Second, how do delayed experience uploads and model deployments affect learning? The policy controls ground robots. A UAV relays communication; the learner stays in the cloud.

**The defensible description is a PANAMA based task policy coupled to an event driven communication simulator, with archived Starlink orbital elements and independently measured packet delay traces.** It is not a validated replica of Starlink's complete radio, scheduling, or TCP system.

There are three evidence categories throughout this guide:

- **Measured:** published packet delay recordings and locally recorded learning outcomes.
- **Derived:** visibility, range, Doppler, propagation, and queue behavior calculated from data and stated equations.
- **Assumed:** capacities, gateway position, satellite selection, handshake messages, robot timing, and controlled contention windows.

The current fast clean curriculum run uses perfect communication. The new LEO module has been exercised in a separate transport workload benchmark. That benchmark measures message delivery; it does not measure robot success. A full mission comparison requires a clean policy qualified at every agent count.

The most useful finding so far is about scale: a roughly 29 ms simulated handshake is brief compared with a one second robot action. A roughly 6.59 MB model snapshot takes seconds to pass through shared links. Those are different mechanisms, and their effects must be reported separately.

**Reading guide:** Sections 1–3 introduce the system. Sections 4–8 explain learning, queues and information age. Sections 9–14 explain satellite data and latency. Sections 15–19 cover experiments, metrics, software, verification and reproduction. Sections 20–21 list primary sources and explain their actual role.

<!-- page -->

## 1 Telecom concepts without the jargon

**Uplink** means toward the remote processor: robot to UAV, and UAV to satellite/cloud. **Downlink** is the reverse direction. The two directions have separate queues and capacity budgets; one can be delayed while the other continues.

**Capacity** is the available data service rate, measured here in megabits per second, Mbps. One byte is eight bits; 50 Mbps means 50 million bits per second. Radio spectrum bandwidth, measured in Hz, is a different quantity. This implementation supplies Mbps directly; it does not derive capacity from spectrum, modulation, interference, or Shannon's formula.

**Latency** is the time from generating a message to receiving it. It can contain several components:

| Component | Meaning | Example |
| --- | --- | --- |
| Propagation | Time for the signal to travel | Range divided by the speed of light |
| Transmission | Time to serialize the bytes onto a link | A 6.59 MB model at 50 Mbps takes about 1.055 s |
| Queueing | Waiting behind other messages | Several robots sharing one downlink |
| Interruption | Service pauses during reassignment | Assumed synchronization and handshake |
| Processing | Time allocated to compute a response | Configurable; currently zero by default |

**Round trip time**, RTT, includes both directions and any response processing. It is not the same as one way delay. The imported dataset measures the directions separately; we do not simply divide RTT by two.

**Handover** transfers service between attachments or resources. Satellite visibility ending, a beam/scheduler reconfiguration, and a brief signaling exchange are distinct events. The orbital model and the SATPIPE periodic benchmark represent different mechanisms; they are not interchangeable clocks.

**Information age** asks how old the state used for a decision is. A cached intention can be outdated even while the physical link is available. Conversely, a robot can continue moving during a communication interruption using its last complete information.

**Doppler** is a frequency shift caused by relative motion. Computing the shift is geometry. Turning it into packet errors requires a receiver and compensation model, which we do not currently simulate.

<!-- page -->

## 2 System architecture and what is isolated

![Mission routes and learning traffic](../tmp/engineering-methods/route_diagram.png)

There is one simulated robot mission per learner. Robot actions are evaluated in batches, grouped by each robot's deployed model version. The mission does not use a pool of Python experience gathering workers. The earlier short screening jobs were separate experiments, not parallel actors inside one mission.

**UAV edge route:** reports cross robot–UAV access. Information processing occurs at the UAV, and updates return over access. Satellite interruption does not disable this local route.

**Cloud route:** reports cross access and satellite uplink. Processing occurs in the cloud; updates return through satellite downlink and UAV access. The satellite hop represents both space legs and the assumed ground network delay.

**Learning traffic:** the learner is in the cloud for both mission routes. Delayed experiences use access uplink followed by satellite uplink. Delayed models use satellite downlink followed by access downlink. Clean or non-delayed directions bypass transport latency as a deliberate experimental control.

The two studies remain separate. In learning experiments, mission observations stay fresh so that differences arise from experience/model transport. In frozen-policy mission experiments, weights stay fixed so that differences arise from selected information caches.

No terrestrial network, imitation policy, communication-triggered stop rule, or new deadlock recovery controller is part of this study. Physical collision resolution remains the retained task simulator's safety/transition rule.

**Code:** `information.py`, `training.py`, `transport.py`, `models.py`. The diagram summarizes simulated routes, not a deployed radio installation.

<!-- page -->

## 3 Robot task and observations

The environment is the fixed MovingAI `random-32-32-10.map`: a 32 by 32 grid with the benchmark's approximately 10% obstacle layout. The obstacle map is not regenerated each episode. Starts and goals are randomized with seeds, using pairs with swapped start/goal cells to create coordination problems. There are four curriculum phases: 2, 4, 6 and 8 agents. [R1, R11]

Each action moves north, south, east or west, or waits. A step is a simultaneous joint action by all robots. The default physical interpretation is one meter per grid cell and one second per joint step. Every training, validation and mission test episode stops by 250 steps.

Success means **all robots occupy their goals simultaneously**. Reaching a goal once is different from remaining there at episode end. A robot may leave its goal; its ever-reached-goal flag remains set. Completion fraction and ever-completion fraction therefore answer different questions.

The retained `0.1` policy receives a 3 by 15 by 15 spatial tensor:

- Local obstacles, sensed fresh.
- Nearby robot positions, sensed fresh.
- Cached path segments of eligible higher-priority peers.

The 12-element vector contains normalized reported A* distance, the ever-reached-goal flag, and five waypoint coordinate pairs. Waypoint offsets are relative to current self-position, divided by the field-of-view radius 7 and clipped to the interval −1 to 1. Distance is normalized using the initial briefing distance and clipped to 0–1.

A* uses four-neighbor movement and static obstacles. It supplies task guidance; the learned policy chooses how to act around other robots. This is A* assisted learned coordination, rather than a policy learning all global navigation from scratch.

The goal remains part of the mission definition during delays. Robots do not forget or randomly replace their goals. The retained policy vector does not include a separate relative-goal coordinate pair; that differs from the vector described in the PANAMA paper.

Truth determines valid movements, collision resolution, rewards and evaluation. Receiver caches determine the selected communicated observation inputs. Keeping those states separate prevents delayed information from corrupting the simulator's physical state.

**Code:** `environment.py` including its `astar_path` function, `information.py`, `config.py`.

<!-- page -->

## 4 Rewards and the important PANAMA differences

| Reward component | Current value | When it applies |
| --- | --- | --- |
| Time | −0.01 | Every robot step |
| Goal arrival | +2.00 | First arrival only |
| Obstacle collision attempt | −1.00 | Proposed invalid move |
| Robot collision attempt | −1.00 | Conflicting proposed move |
| A* distance improvement | 0.23 times improvement | Finite distances, after movement, except when at goal |
| Higher-priority path conflict | −1.00 | Blocking the applicable communicated path |
| Unblocked goal holding | +0.05 | At goal and not blocking |
| Active yielding | 0.00 | Event can be counted; no added reward |

The actual progress term in the retained environment is:

$$r_{\mathrm{progress}}=0.23\left(d_{\mathrm{before}}-d_{\mathrm{after}}\right).$$

Here distances are A* path lengths in grid steps. This rewards reducing distance. It is **not** the discount-correct potential shaping equation specified in the supplied PANAMA paper, which is:

$$F(s,s')=\gamma\Phi(s')-\Phi(s),\qquad\Phi(s)=-0.23d(s,g).$$

At gamma 0.90, moving from distance 10 to 9 gives 0.23 under the retained difference term and 0.437 under the paper's formula. Standing still at distance 10 gives 0 under the difference term and 0.23 under the potential formula, before other rewards. These examples show why the terms cannot be treated as equivalent. Policy-invariance results for potential shaping apply under their mathematical conditions, not automatically to this retained reward. [R1, R9]

Priority is current A* distance plus a tiny ID tie-breaker; smaller values mean higher priority. Ever-completed robots are demoted. Cached received priorities affect the intention channel. Physical conflict resolution and reward checks use current simulator truth, not delayed receiver priorities.

The paper also describes multiple asynchronous actor processes, a network observation channel and penalty, explicit He initialization, and a broader curriculum with a 90% threshold. Here we retain the restored task implementation, use three channels without a network reward, PyTorch's layer defaults, one mission, one map and a 95%/200-case gate. Table IV's 200 for the paper's early random-map stages is an episode step cap, not evidence of 200 validation cases. [R1]

These are material method differences. The current system should be described as **PANAMA based**, with the exact implementation disclosed, rather than an exact reproduction of all paper claims.

<!-- page -->

## 5 Learning equations and model architecture

The spatial branch uses two padded 3 by 3 convolutions, with 32 and 64 output channels, ReLU activations and 2 by 2 max pooling. Its flattened output has 3,136 elements. The vector branch maps 12 to 64 to 32 elements with ReLU. The combined 3,168 elements feed a 512-unit layer and five action values. Parameters are shared across robots.

Double DQN separates selection from evaluation of the next action: [R6]

$$a^*=\operatorname*{arg\,max}_a Q_{\theta}(o',a),\qquad y=r+\gamma(1-z)Q_{\bar\theta}(o',a^*).$$

The policy network has weights θ; the slowly updated target has weights θ̄. Observation o′ is the next observation. The flag z is true at either success or the 250-step timeout in the current implementation, so timeout samples do not bootstrap. This choice must be reported.

Training minimizes a minibatch mean of importance-weighted smooth L1 loss between the current action value and y. The batch size is 64. Gradient norm is clipped at 1. AdamW uses AMSGrad; the current call inherits PyTorch's default weight decay of 0.01. The target update is:

$$\bar\theta\leftarrow(1-\tau)\bar\theta+\tau\theta,\qquad\tau=0.005.$$

Prioritized replay favors samples with large temporal-difference error δ: [R7]

$$p_j=(|\delta_j|+10^{-5})^{0.6},\quad P(j)=\frac{p_j}{\sum_k p_k},\quad w_j\propto\left(NP(j)\right)^{-\beta}.$$

N is the number of received samples in replay. Weights are normalized by the largest weight in the sampled batch. Beta starts at 0.4 and increases to 1 over 60 million **sampled transitions**. The counter advances by 64 per sampled minibatch, not by one per robot step. New transitions enter with the maximum stored priority.

Replay only receives complete, delivered experiences. Existing replay data can be reused during upload delays. The simulator schedules one learning opportunity per generated joint step and skips it if there are insufficient samples.

**Code:** `models.py`, `learning.py`, `replay.py`, `training.py`. Double DQN, prioritized replay and AdamW are algorithmic foundations; their source papers do not validate this mission or communication model. [R6–R8]

<!-- page -->

## 6 Faster learning pilot and what it establishes

Exploration chooses a random action with probability epsilon. Its schedule depends on generated joint steps g, independently of how many experiences arrive:

$$\epsilon(g)=0.1+0.9\exp(-g/K).$$

K is an exponential scale, not the step at which epsilon reaches 0.1. The earlier K of 5 million left epsilon approximately 0.939 at 350,000 steps. With K of 20,000, epsilon is approximately 0.222 at 40,000 steps.

The October 5 screen retained observations, task rewards, network architecture, batch size and optimizer family. Each candidate used fresh seed-42 initialization, 40,000 joint steps, two agents, and a 50,000-transition replay buffer. Greedy checks used 30 shared tuning cases every 10,000 steps.

| Discount gamma | Learning rate | Exploration scale | Final tuning success |
| --- | --- | --- | --- |
| 0.99 | 0.0001 or 0.0003 | 5,000 or 20,000 | 0/30 for all four candidates |
| 0.90 | 0.0003 | 20,000 | 22/30 or 73.3% |
| 0.90 | 0.001 | 20,000 | 26/30 or 86.7% |

The selected screening model separately scored 175/200, or 87.5%, on an independent diagnostic case bank. It had 416 training episodes. Neither score qualifies a phase: the threshold is 95%, with at least 500 training episodes and a complete scheduled qualification check.

Gamma changes the objective, not just speed. A reward k steps away is weighted by gamma to power k. The rough discount horizon, 1/(1−gamma), falls from 100 to 10 steps when gamma changes from 0.99 to 0.90. Because rewards include goal holding and progress, we cannot claim the observed gain comes from exploration alone, or that this pilot preserves the original discounted objective.

`configs/fast_pilot.toml` selects learning rate 0.001, gamma 0.90, K 20,000, replay 50,000 and checkpoints every 50,000 steps. A fresh curriculum run follows; screening weights are not silently promoted. These are measured pilot results, not a guarantee of 4/6/8-agent cooperation or LEO robustness.

**Evidence:** `output/learning-pilots/bootstrap-learning-20261005-01` and its `independent_check/summary.json`; `docs/FAST_PILOT_AND_LEO.md`.

<!-- page -->

## 7 Simulated time and shared link service

Communication uses floating-point simulated timestamps and a heap of events. Time advances with robot steps; a 50 ms delay creates a delivery event at that time, not an operating-system sleep. Wall-clock runtime controls the experiment budget and is a separate clock. Decisions use observations refreshed at robot-step boundaries; subsecond receipt does not issue a new action midway through a step. Report generation and this refresh cycle can leave approximately one step of information age even for millisecond messages. Read realized cache age alongside configured latency.

For a message of B encoded bytes and link capacity C Mbps:

$$t_{\mathrm{tx}}=\frac{8B}{C\,10^6},\qquad t_{\mathrm{prop}}=\frac{\rho}{c}.$$

Both results are in seconds. Range ρ and light speed c must use matching distance units. Queueing starts when a message reaches a link and ends when serialization begins. Interruptions pause satellite serialization; forwarding resumes with the remaining bytes' service time.

$$t_{\mathrm{delivery}}-t_{\mathrm{generation}}=t_{\mathrm{reservation}}+\sum_h\left(t_{\mathrm{queue},h}+t_{\mathrm{tx},h}+t_{\mathrm{interrupt},h}+t_{\mathrm{prop},h}\right)+t_{\mathrm{process}}.$$

The sum runs over hops. Each direction has one shared access or satellite service budget. Each agent has a FIFO subqueue. Agents are selected in cyclic order among ready nonempty queues, and a whole message is sent per turn. This is equal round-robin **message service**, not equal bytes or airtime. Large snapshots can occupy a turn much longer than small messages.

Forwarding is store and forward: the entire message arrives at one hop before the next hop transmits it. There is no packet fragmentation or pipelining within a message. Links may operate simultaneously in separate directions.

Serialization uses Python pickle protocol 5, with memoization disabled, plus an encoded envelope containing sender, kind, source timestamp and version. The logged size is actual bytes for this simulation codec. It is not a measured production wire format and does not include a complete IP/TCP/radio stack.

The transport conserves generated and delivered message bytes and separately counts hop bytes. A message crossing two links is one delivered message but two transmissions. Pending data can be queued, reservation-buffered, transmitting or propagating; occupancy fields must be read with those meanings.

The physical model has no packet loss, retransmission, fading, adaptive modulation, congestion-control algorithm, or competing unrelated Internet users. Those mechanisms cannot be inferred from the current delivery model.

**Code:** `transport.py`; capacity/conservation and immutable-tuple tests.

<!-- page -->

## 8 Cached information and learning transport age

A receiver stores a value, source timestamp, version and, for peer collections, source timestamps for individual peers. Newer information replaces older information; late older messages cannot move the cache or a deployed model backward.

$$\operatorname{age}(t)=\max\left(0,t-t_{\mathrm{source}}\right).$$

For task guidance, the source is the robot report used for remote computation. For collections of intentions or priorities, the aggregate age uses the oldest included source; peer ages are also logged. It is not merely the time since the receiver opened the message.

**Task guidance** stores an absolute route and reported distance. Reached route cells are consumed. The next five stored waypoints are expressed relative to fresh self-position. A late route also consumes cells already visited since its source timestamp. No fresh local A* call repairs delayed receiver guidance. If the robot moves off that cached route, its old waypoints remain old until an update arrives.

**Intentions** retain the last received absolute path segment. **Priorities** retain the last received scalar values for constructing asymmetric intention observations. Local obstacle sensing, local robot sensing and self-position remain fresh. Interventions can select guidance only, intentions only, priorities only, or all three. Nonselected fields are supplied fresh as an experimental control, even in a delayed route.

An initial mission briefing fills caches at time zero. Thus the study tests deterioration after a valid briefing, not a robot deployed without a goal. UAV placement uses reports that have reached the UAV access receiver, rather than silently reading fresh robot positions. Backhaul interruption does not prevent those local reports from arriving.

For learning, an experience preserves observation, action, reward, next observation, terminal flag, generation step and deployed version at creation. Delayed delivery cannot mix steps. A complete model snapshot is applied atomically before the next action; robots keep acting while it is pending.

**Delivery age** is receive time minus generation time. **Replay age** is sampling time minus experience generation time. **Model age** is current time minus the accepted snapshot's publication timestamp. **Version lag** is latest published version minus the robot's deployed version. They are separate quantities. New agents' initial model-age timestamp is their join time, a current initialization convention.

**Code:** `information.py`, `training.py`, `replay.py`.

<!-- page -->

## 9 Orbital data and geographic assumptions

Orbital elements describe a satellite's orbit near a reference time, its **epoch**. They are not a communication schedule or a record of successful customer service. CelesTrak provides general perturbation elements using OMM field names in JSON; those elements are initialized for SGP4 propagation. [R4, R5]

The CelesTrak origin was unavailable during acquisition. The implementation retrieved an archived mirror, preserved the bytes and pinned the matching revision. The source contains 11,037 entries with epochs August 25–31, 2026. We replay six hours beginning **31 August 2026 at 00:00 UTC**, near those epochs. We do not treat propagation to October 5 as today's measured constellation.

The filter retains 10,606 satellites with epochs within three days of the replay start and modeled perigee 350–700 km. It excludes 25 by epoch and 406 by altitude; there were no initialization exclusions or SGP4 error samples in this run. The altitude filter is an operational-shell proxy, not a verified active-service flag.

| Quantity | Implemented choice | Evidence class |
| --- | --- | --- |
| Mission site | 46.2° N, 74.6° W | Assumed remote site near Mont-Tremblant |
| Satellite-terminal altitude | 420 m above sea level | Assumed site 400 m plus UAV 20 m |
| Mission elevation mask | 25° | Assumed minimum angle above local horizon |
| Gateway | 45.3° N, 74.6° W, 300 m ASL | Illustrative; not a provider gateway measurement |
| Gateway mask | 10° | Assumed |
| Geometry sampling | 1 s over 21,600 s | Numerical resolution |
| Orbit source | Archived OMM JSON | Data source; propagated geometry is derived |

Both mission terminal and gateway must see the same satellite. No inter-satellite relay is modeled. On attachment, the simulator chooses the highest-elevation eligible satellite and keeps it until visibility ends. This is an explicit selection policy, not Starlink's proprietary scheduler.

The orbital terminal is fixed at the stated geodetic point. The grid UAV moves over a 32 m local environment, but that displacement and its variable altitude are not fed back into the satellite geometry. Terrain, foliage, weather and antenna pointing errors are omitted. The retained UAV radio model also uses urban coefficients, not a calibrated Québec forest model.

**Data:** `data/leo/orbit_source.json`, `starlink_omm.json`, `tremblant_6h.npz` and its JSON metadata. Immutable source and hashes appear in Section 19.

<!-- page -->

## 10 Orbital geometry equations

SGP4 predicts position and velocity from the archived orbital elements. Its output frame is TEME, an Earth-centered astronomical frame; positions are in kilometers and velocities in kilometers per second. We use the Vallado implementation through `sgp4`, rather than inventing circular satellites at equally spaced angles. [R5, R12]

The observer uses a WGS84 ellipsoid. Latitude φ and longitude λ are in radians; altitude H is in km. Equatorial radius a is 6,378.137 km and squared eccentricity e² is 0.00669437999014:

$$N=\frac{a}{\sqrt{1-e^2\sin^2\phi}},\qquad \mathbf{o}=\begin{bmatrix}(N+H)\cos\phi\cos\lambda\\(N+H)\cos\phi\sin\lambda\\(N(1-e^2)+H)\sin\phi\end{bmatrix}.$$

TEME is rotated into Earth-fixed ECEF using Greenwich mean sidereal angle θ. The velocity correction accounts for Earth's rotation:

$$\mathbf{r}_{E}=R_z(-\theta)\mathbf{r}_{T},\qquad \mathbf{v}_{E}=R_z(-\theta)\mathbf{v}_{T}-\boldsymbol{\omega}_{E}\times\mathbf{r}_{E}.$$

Earth rate is 0.0000729211514670698 rad/s. The code uses Vallado's GMST polynomial, approximates UT1 by UTC, and omits polar motion. This is an engineering coordinate conversion approximation; it is not a high-precision Earth-orientation solution.

For satellite position r and fixed observer o, define the line-of-sight unit vector l and local geodetic up vector u:

$$\rho=\|\mathbf{r}_{E}-\mathbf{o}\|,\qquad \mathbf{l}=\frac{\mathbf{r}_{E}-\mathbf{o}}{\rho},\qquad E=\arcsin(\mathbf{l}\cdot\mathbf{u}).$$

A contact is eligible if both E values exceed their masks and propagation succeeded. Range is slant distance, not satellite altitude. The one-way space path goes terminal to satellite to gateway:

$$t_{\mathrm{space}}=\frac{\rho_{\mathrm{terminal}}+\rho_{\mathrm{gateway}}}{299792.458},\qquad t_{\mathrm{backhaul,prop}}=t_{\mathrm{space}}+0.010.$$

Ranges are in km; resulting delays are seconds. The added 10 ms is an assumed ground-network delay. In the six-hour selected timeline, total one-way propagation ranges from 12.48 to 18.14 ms, averaging 14.68 ms. These values are calculated geometry plus the assumption, not measured packet delays.

**Code:** `leo.py`, `scripts/build_leo_timeline.py`.

<!-- page -->

## 11 Doppler and individual attachment handshakes

For a fixed ECEF observer, radial range rate is the velocity projected on the line of sight. First-order geometric Doppler is:

$$\dot\rho=\mathbf{v}_{E}\cdot\mathbf{l},\qquad f_D=-\frac{f_c\dot\rho}{c}.$$

Positive range rate means receding, so received frequency shifts downward. Carrier frequency f_c is in Hz; range rate and c must share units. The assumed uplink and downlink carriers are 14.25 and 11.7 GHz. The selected timeline spans approximately −309 to +150 kHz uplink and −254 to +123 kHz downlink raw shift.

**Ideal compensation is assumed.** No residual frequency error, tracking acquisition time, Doppler-dependent capacity, or packet error probability is implemented. Doppler telemetry therefore does not establish an outage or a model of Starlink receiver performance.

Each new attachment includes an explicitly assumed signaling sequence:

![Assumed attachment exchange](../tmp/engineering-methods/handshake_diagram.png)

Synchronization costs 5 ms. Request and complete processing each cost 5 ms. Every control packet incurs the terminal–satellite–gateway space propagation p, without the extra ground delay. Total control bytes are 384, counted separately from ordinary data workload:

$$t_H=0.005+0.010+4p+\frac{8(128)}{10\times10^6}+\frac{8(256)}{50\times10^6}.$$

This models a sequential four-message exchange. It is not a measured Starlink signaling protocol. Satellite data forwarding buffers until attachment completes; access exchange continues. Control messages set the interruption duration rather than competing as ordinary data in the link queue.

The archived six-hour timeline records 172 satellite identity changes, approximately 28.7 per hour. Dividing 21,600 s by 172 gives an aggregate 125.6 s per change. Mean assumed handshake duration, including initial attachment, is 28.78 ms. No sampled interval lacked an eligible satellite; the mean eligible count was 76.4, minimum 53. These are consequences of the snapshot, masks, gateway and selection rule, not universal Starlink service statistics.

<!-- page -->

## 12 Profiles and parameter assumptions

**Perfect profile:** communication is immediate. It is the clean learning reference and the zero-delay equivalence control.

**Controlled profile:** seeded schedules choose one or two reservation windows per agent per episode. Each window lasts two robot steps. Messages generated in an applicable window receive an additional 1, 2, 5, 10 or 20 steps of delay. FIFO holding prevents a newer message of the same agent/kind from bypassing the delayed flow. These are deliberate stress conditions, not measured handover durations. Physical link serialization and propagation are bypassed in this profile.

Schedules are independent of policy actions. Realized exposure depends on actual message generation and whether the episode lasts long enough to reach a window. Early successful completion is not extended to manufacture stale events.

**Physical profile:** shared capacity, serialization, propagation and interruption are modeled. It can use the orbit timeline or imported delays, but cannot combine them and double-count the same hop.

| Parameter | Value | Status and interpretation |
| --- | --- | --- |
| Robot time | 1 s per joint step | Assumption; configurable |
| Access capacity UL / DL | 50 / 50 Mbps | Assumed shared service budgets |
| Satellite capacity UL / DL | 10 / 50 Mbps | Assumed shared service budgets |
| Default satellite propagation | 25 ms one way | Assumption when no orbit or trace replaces it |
| Orbit ground component | 10 ms one way | Assumed addition to calculated space delay |
| Edge / cloud processing | 0 / 0 s | Default abstraction; no CPU resource scheduler |
| Periodic interruption | 50 ms every 15 s | SATPIPE informed sensitivity benchmark |
| Orbit attachment | About 28.8 ms on average | Derived using assumed signaling |

SATPIPE reports roughly 15 s scheduling/reassignment cycles and approximately 50 ms link interruptions in its measured setup, with TCP effects lasting longer. We use those values as a separate periodic sensitivity model. We do not implement SATPIPE's TCP algorithm, its loss behavior, or a seconds-long TCP recovery response. [R2, introduction and Section III]

Controlled delays and orbital handshakes answer different questions: how robust is a policy to selected age, versus what age this specified transport model produces? Their result labels should preserve that distinction.

<!-- page -->

## 13 Actual one way delay recordings

The public dataset accompanying Garcia, Sundberg and Brunstrom's LEO-NET 2025 paper supplies real Starlink one-way packet delays. Measurements were made at an unobstructed terminal in **Karlstad, Sweden, during April 2025**, using two ports of one hardware-timestamping NIC with a shared clock. They are not Mont-Tremblant measurements. [R3, R10]

The paper used 150-byte UDP/IP probes at about 3,750 packets/s under light load. This characterizes packet latency, not multi-megabyte model transfer time. The current importer rejects model snapshots routed through those empirical satellite traces. Applying packet delays to larger information or experience messages still remains an explicit size/workload extrapolation. [R10, Section 3]

We extracted the paired recording `2025-04-11-15-16-16` from the archive:

| Direction | Packets | Mean | 95th percentile | Maximum |
| --- | --- | --- | --- | --- |
| Uplink | 187,624 | 30.45 ms | 42.83 ms | 122.74 ms |
| Downlink | 187,745 | 25.83 ms | 31.37 ms | 92.72 ms |

![Measured directional packet delay distributions](../output/leo/tremblant-data-20261005-01/measured_one_way_delay.png)

The plot uses measured data. The timeline thins points for display; the cumulative distributions and statistics include every imported sample. The recording is about 50 s, so it cannot support a 250 s episode by silent repetition, stretching or extrapolation.

Raw direction, nanosecond timestamps, sequence numbers, units, segment limits and SHA-256 hashes are retained. Missing sequence numbers are not automatically packet losses, and spikes are not confirmed handovers. Per-member ZIP CRC is verified; the publisher's whole-archive MD5 is recorded but cannot be verified from partial downloads. [R3]

The trace replaces the entire modeled satellite-hop delay at the corresponding timestamp. It is not added to orbital propagation, satellite queueing or periodic handover delay. Access remains modeled. This replacement avoids counting latency already present in the measurement twice.

<!-- page -->

## 14 Why model transfer can dominate handover

The transport benchmark generates one experience per agent per step and publishes fixed seed-42 snapshots every 16 steps for 250 steps. It then drains pending traffic. It preserves encoded task observation shapes but uses a fixed traffic template; no learning or robot success is measured.

A model payload has 6,591,088 bytes before the small envelope, approximately 6.59 MB. At 50 Mbps, one hop takes about 1.055 s. The satellite and access downlinks use whole-message store and forward, so a single snapshot needs at least approximately 2.11 s plus propagation, even without queueing.

Snapshots are sent **separately to each agent over both links**. Average offered snapshot traffic is:

$$L_{\mathrm{models}}=\frac{n\,8B}{16\ \mathrm{s}}.$$

With eight agents, that is about 26.36 Mbps on each modeled downlink. This per-agent unicast design is an assumption. Sending one cloud copy to the UAV and multicasting locally could greatly reduce satellite traffic, but is not the current implementation.

| Agents | Mean experience age | Mean model age at delivery | Maximum model age |
| --- | --- | --- | --- |
| 2 | 22.97 ms | 2.65 s | 3.18 s |
| 4 | 27.86 ms | 3.71 s | 5.29 s |
| 6 | 32.74 ms | 4.76 s | 7.40 s |
| 8 | 37.63 ms | 5.81 s | 9.53 s |

These are simulated transport results with orbital handshakes enabled, using the historical timeline segment beginning at second 1,000. The paired control keeps geometry, capacities and propagation identical and disables only handshake interruption.

In this workload, the mean experience-age increment from handshakes is about 0.217 ms; mean model-age change is near zero at 2/4/6 agents and about 0.203 ms at eight. Large baseline model ages therefore come mainly from serialization and shared queues, not from handovers.

A 250 s mission encounters about two orbit-selected changes on aggregate, versus around sixteen 15 s periodic scheduling events. Neither guarantees harmful policy effects: delays must occur at sensitive decisions, and the policy must depend on the aged input. Effects on success remain an empirical question.

**Evidence:** `output/leo/tremblant-data-20261005-01/summary.csv`, `events.jsonl`, `manifest.json` and `scripts/benchmark_leo_transport.py`.

<!-- page -->

## 15 Experiment protocol and qualification

**Learning study:** seed 42, matched fresh initialization, fresh mission information, and four separate conditions:

| Condition | Experience upload | Model deployment |
| --- | --- | --- |
| Clean | Immediate | Immediate |
| Uplink delayed | Controlled delay | Immediate |
| Downlink delayed | Immediate | Controlled delay |
| Combined | Controlled delay | Controlled delay |

One learner opportunity follows each generated joint step. Model versions are published every 16 generated steps in every condition. Experiences already in replay can support updates during upload holds. Snapshot arrival during an episode changes that robot's deployed policy atomically; it does not freeze the mission.

Each condition has three hours including initialization, validation and checkpointing, with a 60 s shutdown reserve. Budget exhaustion means partial, not graduation. The selected fast clean run is a baseline pilot; the four-arm delayed comparison must use matching selected hyperparameters if it proceeds.

A phase can graduate only after at least 500 training episodes and a complete greedy validation of 200 cases at 95% success or higher. Checks occur every 250 training episodes after that minimum: 500, 750, 1,000 and so on. At least 190/200 successes are needed. Validation tests the current learner policy with fresh mission information, not each robot's currently delayed model. Separate transport metrics expose deployed-policy age and version lag.

**Frozen-policy mission study:** freeze the qualified clean final model, then pair 50 held-out cases per agent count across perfect communication and guidance-only, intentions-only, priorities-only and all-three interventions. Sweep 1/2/5/10/20-step controlled delay for UAV edge and cloud routes. Physical handover, contention and combined tests are separate treatments.

All episodes retain the 250-step cap and the same success rule. The clean reference is shared where routes are equivalent. Controlled routes also coincide when their processing defaults are zero and physical link delay is bypassed; a route label alone creates no latency difference.

Compare learning curves over the common generated-step range, and also report wall time and received samples. One seed is a pilot, not a robust estimate of training variability. Paired mission cases and bootstrap intervals are implemented; further independent training seeds would strengthen a paper. Repeated qualification checks use a gate, not proof that population success is at least 95%.

<!-- page -->

## 16 Metrics and how to interpret them

For M episodes with success indicator S_e and length T_e:

$$\mathrm{SR}=100\frac{\sum_e S_e}{M},\qquad \mathrm{PAR2}=\frac{1}{M}\sum_e\left[S_eT_e+(1-S_e)500\right].$$

Success-rate axes use 0–100%. Successful makespan is T_e only for successful episodes and is undefined for failures. PAR-2 assigns a failed episode twice the 250-step cap, or 500 steps. Reporting both prevents a failing policy from appearing efficient just because its few successes finish quickly. PAR-2 is a reporting convention, not a physical mission duration.

Completion fraction is the fraction currently at goals at episode end. Ever-completion fraction is the fraction that reached a goal at least once. Report both without substituting either for all-agent success.

**Collision attempts** count invalid obstacle proposals and robots whose conflict resolution records an agent collision attempt. The simulator resolves conflicting moves, so this is a demand on collision handling, not a measured physical crash count or necessarily one count per pair.

UAV travel sums three-dimensional movement:

$$D_{\mathrm{UAV}}=\sum_t\|\mathbf{u}_{t+1}-\mathbf{u}_t\|_2.$$

Positions are in meters. This includes vertical travel. It is not an energy estimate: no propulsion power, battery or aerodynamic model is currently used.

Information-age distributions use source timestamps, including peer-level age and the aggregate oldest-source definition. Summaries alone can conceal short critical intervals; per-agent traces show cache route, information age and actual position together.

Learning telemetry separates generated joint steps, delivered agent experiences, learning opportunities, actual learner updates, model publications, deployed versions, version lag, delivery ages and replay ages. There are n generated agent experiences per joint step, rather than n environment steps. An experience from an earlier curriculum phase can be delivered but excluded from the new phase's replay; this exclusion is counted.

Queue occupancy is reported by link plus reservation-buffer and in-flight categories. A queued byte is not a lost byte. Delivered traffic counts end-to-end bytes separately from hop transmission bytes. Scheduled windows, messages actually exposed and realized windows per agent distinguish planned treatment from actual exposure.

Inference summaries support paired differences against the shared reference and bootstrap confidence intervals over matched cases. Report the number of successes with means, especially at 50 cases where one outcome changes success rate by two percentage points.

**Code:** `evaluation.py`, `training.py`, `records.py`, reporting modules.

<!-- page -->

## 17 UAV radio model and software libraries

The retained air-to-ground diagnostic uses the probabilistic line-of-sight model presented in the supplied aerial-base-station paper. At horizontal range r and UAV height h, elevation angle θ is in degrees: [R13, Section II and Table I]

$$P_{\mathrm{LoS}}=\frac{1}{1+a\exp[-b(\theta-a)]},\qquad\theta=\frac{180}{\pi}\arctan(h/r).$$

$$L=20\log_{10}\!\left(\frac{4\pi f_c\sqrt{h^2+r^2}}{c}\right)+P_{\mathrm{LoS}}\eta_L+(1-P_{\mathrm{LoS}})\eta_N.$$

The current urban coefficients are a 9.61, b 0.16, line-of-sight excess loss 1 dB and non-line-of-sight loss 20 dB. The carrier is 2.5 GHz and allowed path loss is 85 dB. The recorded effective SNR is the −8.47 dB threshold plus the allowed-loss margin. Without a specified transmit power, noise figure and interference budget, it should be understood as an equivalent link-quality diagnostic.

The UAV finds candidate horizontal disk centers to cover reported robots, favors coverage count, then required radius and movement, and adjusts altitude with a 20 m minimum. Motion is limited to 1 m per step. This is a geometric controller, not a learned UAV policy or the paper's full revenue optimization solver. **Coverage and SNR do not gate transport capacity or delivery in this study**, and no SNR reward is used. [R13; `uav.py`]

| Library and audited version | Actual role |
| --- | --- |
| Python 3.12 | Main simulator, events and orchestration |
| PyTorch 2.11.0+cu128 | DQN, optimizer, batched inference; CUDA training |
| NumPy 2.4.4 | Observations, random streams, geometry arrays and NPZ data |
| sgp4 2.27 | Vallado satellite propagator; loaded from the LEO dependency directory |
| Matplotlib 3.10.9 | Measured and simulated scientific plots |
| tqdm 4.70.0 | Progress display; no simulated communication delay |
| pytest 9.1.1 | Acceptance tests; separate test dependency directory |
| SciPy 1.17.1 | Declared/installed dependency; no current source imports found |

Standard-library `heapq`, `collections`, `pickle`, `json`, `hashlib`, `zipfile`, `urllib` and `tomllib` implement event scheduling, queues, serialization, provenance, downloads and configuration. Optional `pygame-ce` is declared but not installed in the audited training environment. Skyfield, ns-3, STK and a telecom PHY simulator are not used. Versions above describe the audited machine, not minimum requirements in `pyproject.toml`.

<!-- page -->

## 18 Verification and remaining integration limits

The acceptance suite checks fixed-action zero-delay behavior against a retained `0.1` fixture, including positions, rewards, observations and UAV state. It checks absolute cached guidance, field isolation, capacity sharing and byte conservation, continued robot motion during learning delays, undelivered-experience exclusion, complete atomic models, monotonic versions, exact pending-event continuation, the 250-step cap and strict qualification.

The added LEO tests check coordinate/range-rate behavior, individual handshake messages and timing, satellite-only interruptions, local UAV exchange during backhaul holds, buffering, timeline bounds, dataset header/unit preservation, trace replacement, and rejection of mixed orbit/trace modeling or bulk models through packet traces. All 40 tests passed in the document audit on October 5. A passing suite establishes software behavior under its tests; it does not validate an actual Starlink installation.

Three implementation details found during this document audit should be kept visible:

- The generic episode trace `handover_windows` helper still emits periodic 15 s windows even when an orbital timeline is loaded. For orbit studies, the timeline's `handover_events` and actual transport interruption events are authoritative. Reconcile the generic replay overlay before publishing orbit-based replay visuals.
- The transport benchmark manifest's nested `communication` object contains the base configuration. The script overrides it with physical transport, an orbital timeline, no contention and a 1,000 s offset. The explicit benchmark fields, script and transport records establish those effective settings. A consolidated effective configuration would make this easier to audit.
- Physical mission treatments compared only against perfect communication include serialization and propagation as well as their named intervention. A handover-only causal claim needs a capacity/geometry/propagation-matched reference with handshakes disabled, as already used in the transport benchmark.

These findings do not justify replacing measured results or changing a live run. The report describes the current implementation and its limits.

Before a paper makes deployment claims, the highest-value additions are measured local access/backhaul calibration; packetization and a bulk transport protocol; gateway/scheduler sensitivity; residual Doppler and blockage modeling if claimed; capacity-matched mission controls; multiple training seeds; and qualified frozen-policy comparisons. They are future work, not hidden parts of this simulator.

Semantic offloading, priority-based bandwidth optimization, optical inter-satellite links, energy models and online learning in a deployed robotic system remain deferred. The supplied remote-robotic SAGIN draft motivates those directions, but its proposed system is not fully implemented here. [R14]

<!-- page -->

## 19 Reproduction and implementation traceability

The repository root for this audit is `D:/Projects/PANAMA+UAV/panama_uav`, on branch `codex/comm-cut-off-impact`, restored from baseline commit `91f75e6`. The communication/LEO implementation includes uncommitted work; that commit alone cannot reproduce it. Each training run freezes source copies and records hashes. Communication schema version is 3.

| Component | Main implementation or artifact |
| --- | --- |
| Task, observations, rewards | `src/panama_uav/environment.py` |
| Absolute caches and processing routes | `src/panama_uav/information.py` |
| Link queues, trace import, event clock | `src/panama_uav/transport.py` |
| Geometry and handshake timing | `src/panama_uav/leo.py` |
| Orbital acquisition and generation | `scripts/fetch_starlink_orbits.py`, `scripts/build_leo_timeline.py` |
| Empirical acquisition | `scripts/fetch_starlink_delays.py` |
| Learning and replay | `training.py`, `learning.py`, `replay.py` under `src/panama_uav` |
| Frozen paired evaluation | `src/panama_uav/evaluation.py` |
| Effective pilot and LEO selections | `configs/fast_pilot.toml`, `configs/leo_tremblant.toml` |

For an independent regeneration, from the repository root:

```powershell
python -m pip install "sgp4>=2.27"
python scripts/fetch_starlink_orbits.py
python scripts/fetch_starlink_delays.py --pair-index 0
python scripts/build_leo_timeline.py --start 2026-08-31T00:00:00+00:00
python scripts/benchmark_leo_transport.py --output output/leo/new-unique-run
```

Those commands acquire data and create a new transport benchmark; they do not qualify a robot model. Preserve the existing snapshot for exact reproduction: a new live acquisition can change the data or require a different replay epoch. Use a unique output/run ID. Do not run acquisition over files in use by a live physical experiment.

The orbital source SHA-256 is `b41fb2032d0ad72744e4234804fa66928f5e26445e8950764cce8789f35d8224`. The immutable mirror revision is `3c90be864dc8b3b8899a3cc3477957ae1e61564c`. The resulting timeline SHA-256 recorded by the benchmark is `f6014120b6283bf6e8fe988012e123a2c64b708fc2a2b864246a1eda3df50931`.

The dataset manifest retains both extracted CSV hashes, original member names and timestamps. Checkpoints retain pending messages, clocks, caches, deployed models, replay, counters and random states. Code, configuration, map and backhaul hashes protect continuation from silently changed semantics.

<!-- page -->

## 20 Primary sources and their actual role

**R1 PANAMA supplied paper.** Arman Dogru, R. Irem Bor-Yaliniz and Nimal Gamini Senarath, *PANAMA A Network-Aware MARL Framework for Multi-Agent Path Finding in Digital Twin Ecosystems*. Local file `docs/papers/PANAMA.pdf`. Used for the task-policy lineage, asymmetric intentions, Double DQN/PER and comparison of method differences. Sections II–IV and Tables I, III and IV. Publication metadata is not invented from the local manuscript.

**R2 SATPIPE.** Ding Zhao, Xinyu Zhang and Myungjin Lee, *SATPIPE Deterministic TCP Adaptation for Highly Dynamic LEO Satellite Networks*, IEEE INFOCOM 2025. Its measurements motivate the separate 15 s / 50 ms periodic sensitivity profile. Its TCP controller and recovery behavior are not implemented. [Author-hosted paper](https://xyzhang.ucsd.edu/papers/Ding.Zhao_INFOCOM25_SatPipe.pdf).

**R3 One way delay dataset.** Johan Garcia and Simon Sundberg, *Dataset for A Detailed Characterization of Starlink One-way Delay*, Zenodo, v1, 21 July 2025. Used for paired directional empirical delay samples and their acquisition conventions. [Dataset and README](https://zenodo.org/records/16275284).

**R4 CelesTrak GP data documentation.** *A New Way to Obtain GP Data*. Explains OMM fields and JSON GP formats compatible with SGP4. [Provider documentation](https://celestrak.org/NORAD/documentation/gp-data-formats.php). The actual archived bytes came through the [pinned mirror snapshot](https://raw.githubusercontent.com/satvisorcom/satvisor-data/3c90be864dc8b3b8899a3cc3477957ae1e61564c/celestrak/json/starlink.json), not a successful origin fetch on the audit date.

**R5 SGP4 implementation documentation.** Brandon Rhodes and contributors, `sgp4`, version 2.27 used locally. Explains OMM initialization, TEME outputs, units and the Vallado propagator implementation. [Project documentation](https://pypi.org/project/sgp4/). Its numerical agreement with reference code is not a claim of exact real satellite positions.

**R6 Double DQN.** Hado van Hasselt, Arthur Guez and David Silver, *Deep Reinforcement Learning with Double Q-learning*, arXiv:1509.06461, 2015; AAAI 2016. Used for selecting the next action with the policy network and evaluating it with the target. [Author paper](https://arxiv.org/abs/1509.06461).

**R7 Prioritized replay.** Tom Schaul, John Quan, Ioannis Antonoglou and David Silver, *Prioritized Experience Replay*, arXiv:1511.05952, 2015; ICLR 2016. Used for error-based sampling and importance correction. [Author paper](https://arxiv.org/abs/1511.05952).

<!-- page -->

## 21 Further sources and evidence boundaries

**R8 AdamW.** Ilya Loshchilov and Frank Hutter, *Decoupled Weight Decay Regularization*, arXiv:1711.05101, 2017; ICLR 2019. Basis of the retained optimizer family. Exact settings come from the source call and the installed PyTorch implementation, not this paper alone. [Author paper](https://arxiv.org/abs/1711.05101).

**R9 Potential reward shaping.** Andrew Y. Ng, Daishi Harada and Stuart Russell, *Policy Invariance Under Reward Transformations Theory and Application to Reward Shaping*, ICML 1999. Used to explain the distinction between discount-correct potential shaping and retained raw distance improvement. [Author-hosted paper](https://people.eecs.berkeley.edu/~russell/papers/icml99-shaping.pdf).

**R10 One way delay paper.** Johan Garcia, Simon Sundberg and Anna Brunstrom, *A Detailed Characterization of Starlink One-way Delay*, 3rd Workshop on LEO Networking and Communication, 2025, DOI 10.1145/3748749.3749090. Section 3 supports the probe-size, hardware-timestamp and light-load interpretation. [Publisher record](https://doi.org/10.1145/3748749.3749090); [author-uploaded full text](https://www.researchgate.net/publication/393884400_A_Detailed_Characterization_of_Starlink_One-way_Delay).

**R11 MovingAI benchmark.** *MAPF Benchmarks*, Moving AI Lab. Source of the fixed random map. This study generates seeded swapped-pair cases; it does not claim the full published benchmark scenario distribution. [Benchmark provider](https://www.movingai.com/benchmarks/mapf.html).

**R12 SGP4 mathematical reference.** David A. Vallado, Paul Crawford, Richard Hujsak and T. S. Kelso, *Revisiting Spacetrack Report 3*, AIAA 2006-6753, 2006. Basis for the propagator and coordinate conventions; current conversion retains the stated Earth-orientation approximations. [Author/provider reference and software](https://celestrak.org/publications/AIAA/2006-6753/).

**R13 Aerial base station paper.** R. Irem Bor Yaliniz, Amr El-Keyi and Halim Yanikomeroglu, *Efficient 3-D Placement of an Aerial Base Station in Next Generation Cellular Networks*, 2016. Local file `docs/papers/AERIAL_BS_UAV.pdf`; Section II and Table I supply the air-to-ground model and coefficients. The current candidate-disk UAV controller is a simplified implementation, not the full optimization in that paper. [Author preprint](https://arxiv.org/abs/1603.00300).

**R14 Supplied SAGIN draft.** Irem Bor-Yaliniz, Arman Dogru and Georges Kaddoum, *Joint SAGIN Resource Allocation and MAPF for Digital Twin Supported Remote Robotic Applications*. Supplied file `C:/Users/adogr056/Downloads/Remote_Robotic_Satellite.pdf`. This two-page draft motivates remote robotics, semantic offloading and joint resource design. Its proposed optical routing, semantic/resource optimization and energy analysis are not implemented in this first staleness study.

Web sources were checked on 5 October 2026. Numerical simulation and pilot values in this guide come from the named local records, rather than copied performance claims from the cited papers. No curves have been synthetically extended.
