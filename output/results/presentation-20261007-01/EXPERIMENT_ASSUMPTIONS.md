# Proposed real-data-informed experiments

We will study **mission agent → UAV relay → LEO satellite → ground station
→ cloud**, with replies returning along the reverse route. The current
PANAMA agents are ground robots; representing mission drones would assume
motion constrained to the same modeled plane. Communication uses one
satellite relay and no inter-satellite routing. The goal is to measure how
information age affects coordination, and separately how delayed experience
uploads and model deployments affect learning.

**Dataset use.** [CelesTrak Starlink GP/OMM-compatible orbital elements](https://celestrak.org/NORAD/documentation/gp-data-formats.php),
propagated using [Vallado et al.'s SGP4 implementation](https://celestrak.org/publications/AIAA/2006-6753/),
provide satellite positions and velocities. We derive visibility, slant
range, propagation and Doppler for a remote site near Mont-Tremblant.
The existing archived snapshot was obtained from a
[pinned mirror](https://raw.githubusercontent.com/satvisorcom/satvisor-data/3c90be864dc8b3b8899a3cc3477957ae1e61564c/celestrak/json/starlink.json)
and replayed near its August 2026 epochs. These data do not reveal Starlink's
actual serving-satellite assignments.

[Garcia and Sundberg's Starlink One-way Delay dataset](https://zenodo.org/records/16275284)
provides hardware-timestamped uplink/downlink measurements from Karlstad,
Sweden, in April 2025. It supplies a separate empirical transport sensitivity
case, not local Canadian measurements. Directions, timestamps, units and
source hashes are preserved. The currently imported pair covers about
50 seconds; full mission tests require longer continuous recordings, without
looping or extrapolating this pair. UDP probe latency cannot alone calibrate
bulk model-transfer throughput.

[MovingAI MAPF benchmarks](https://www.movingai.com/benchmarks/mapf.html)
supply the obstacle map. Our own seeded start/goal cases provide the task
instances; we do not use the published scenario bank. The task policy is
PANAMA based, rather than a claim of exact paper reproduction.

**Formulations.** For satellite position \(r\), observer \(o\), local-up vector
\(u\), encoded message size \(B\) bytes and capacity \(C\) bits/s:

\[
\rho=\|r-o\|,\quad E=\arcsin\left(\frac{r-o}{\rho}\cdot u\right),\quad
\tau_{space}=\frac{\rho_{UAV}+\rho_{gateway}}{c},\quad
\tau_{tx}=\frac{8B}{C}.
\]

\[
D=\tau_{reservation}+\tau_{processing}+\sum_h
(\tau_{queue,h}+\tau_{tx,h}+\tau_{prop,h}+\tau_{interrupt,h}),\qquad
A(t)=t-t_{source}.
\]

These are range/light-speed propagation, link serialization and timestamped
age calculations in our event-driven simulation. Doppler is
\(f_D=-f_c\dot\rho/c\); ideal compensation is assumed, so Doppler does not
produce simulated packet errors. Shared uplink/downlink queues use FIFO per
agent with round-robin whole-message service and store-and-forward links.

**Explicit assumptions.** One robot step is one second. The fixed orbital
observer is 46.2° N, 74.6° W, 420 m ASL; the illustrative gateway is
45.3° N, 74.6° W, 300 m ASL, not a measured provider gateway. Both must see
the same satellite above respective 25°/10° masks. Select the highest
eligible elevation at attachment and retain it until visibility ends.
Access capacities are 50/50 Mbps UL/DL; satellite backhaul capacities are
10/50 Mbps; the extra ground-network propagation is 10 ms one way.
These capacities, gateway, selection rule and handshake are assumptions.

The orbital handshake is an assumed four-message exchange with 128 total
uplink bytes, 256 downlink bytes, 5 ms synchronization and two 5 ms processing
delays:
\[
H=0.015+4\tau_{space}+\frac{8(128)}{10\times10^6}
+\frac{8(256)}{50\times10^6}\quad\text{seconds}.
\]
It averages approximately 28.8 ms in our selected timeline. Separately,
[SATPIPE, INFOCOM 2025](https://xyzhang.ucsd.edu/papers/Ding.Zhao_INFOCOM25_SatPipe.pdf)
informs a periodic sensitivity case of approximately 50 ms interruptions
every 15 seconds. That schedule is not inferred from orbital visibility and
is not stacked on the orbital handover schedule. We do not implement
SATPIPE's TCP behavior. Trace-driven backhaul delay replaces the corresponding
modeled delay; it is not added on top of it.

**Comparison design.** Use identical held-out cases and a frozen policy for
mission tests, isolating stale A* guidance, intentions, priorities and their
combination. Goals and local sensing remain fresh, and agents continue acting.
Fresh matched learning runs isolate experience-upload and model-deployment
delays. Report success, all-case episode length, successful makespan, PAR-2
and realized information/model age. Keep measured delay, derived geometry
and controlled stress delays separate. Missing sequence numbers alone are
not packet loss; delay spikes alone do not confirm handovers. Packet loss,
TCP recovery, weather and residual Doppler impairment are not modeled.

**Short message for reuse:**

We plan to study mission agent → UAV → LEO → ground station → cloud, using
a single satellite relay. CelesTrak orbital elements propagated with SGP4
will provide visibility, range, propagation and Doppler near Mont-Tremblant.
Garcia and Sundberg's hardware-timestamped Starlink one-way delay dataset
will provide a separate measured uplink/downlink sensitivity case; it was
recorded in Sweden, not at our mission site. MovingAI provides the task map.

Delay is computed as propagation \((\rho_{UAV}+\rho_{gateway})/c\),
serialization \(8B/C\), queueing, processing and handover interruption.
Information age is \(t-t_{source}\). Capacities, gateway location, satellite
selection and the orbital handshake remain stated assumptions. SATPIPE's
approximately 50 ms interruptions every 15 seconds form a separate
measurement-informed comparison, not a substitute for observed assignments.

We will compare paired cases with fresh versus stale guidance, intentions
and priorities, then separately test delayed experience uploads and model
deployments. Goals and local sensing remain fresh. Success, average episode
length, successful makespan and realized age will be reported. The existing
50-second delay recordings need longer continuous segments for full mission
tests; they will not be repeated to manufacture coverage. This is a
data-informed communication simulation, not a validated replica of Starlink.
