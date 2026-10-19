# LEO scheduler recovery, October 9, 2026

The Clean reference qualified all four phases. The original Combined worker
stopped generating records after step 31,775 while consuming a CPU core.
A live stack capture (`diagnostics/stalled_stack.txt` in the original run)
identified `OrbitTimeline.service`, not policy learning or radio propagation.

At absolute simulated time 32,775.06 s, floating-point division classified a
frame boundary as the previous frame. Adding the frame duration reconstructed
the same current timestamp. The guard branch repeatedly set `cursor` to itself.
No transmission, environment step, validation or budget check could complete.

The fix classifies frames against their representable boundary products and
requires guard transitions to move forward. It changes no learning parameters,
rewards, orbital data, allocated bandwidth, frame duration or guard fraction.
Regression tests include the exact failing service request and boundaries up to
the planned 80-million-step clock range, with a subprocess timeout. Recovery
also exposed a CUDA checkpoint issue: loading all tensors onto the GPU moves
saved random-generator byte states there too, but PyTorch requires CPU byte
states when restoring generators. The fix moves those saved byte tensors back
to CPU without changing their contents. A CUDA regression with deterministic
test kernels checks identical continued records and policy weights after
save/load; it does not change the production worker's CUDA kernel settings.

The original monitor verified process identities and recorded snapshots but
failed to classify unchanged progress as a stall. Monitoring now reports stale
training/validation/checkpoint activity explicitly. Controllers check progress
every 30 seconds and terminate their own stalled worker after ten minutes,
preserving the last fully written checkpoint and recording a failure. They do
not repeatedly restart failed workers or force curriculum qualification.

Recovery uses a new run directory and preserves the original frozen source,
checkpoint and logs. It copies the qualified Clean reference unchanged. Combined
resumes from the complete 25,000-step checkpoint with its optimizer, replay,
pending messages, simulated clocks, model versions and random-generator states.
Only the checkpoint's run identity changes. Logs are copied through their saved
checkpoint byte offsets so uncheckpointed work is not counted twice. The
6,775 later original steps remain archived; the continuation recomputes them.

`recovery.json` records lineage, hashes, offsets and the numerical code revision.
Plots include this provenance in `plot_manifest.json`. The original 12-hour
allocation resumes from its saved 590.203 seconds of elapsed work; infrastructure
hang and recovery time are excluded explicitly, not represented as learning
time. The reference and continuation have different `leo.py` hashes, disclosed
as this numerical correction. `training.py` also differs solely for restoring
CUDA random-generator state. Other policy implementation hashes are identical.

The first recovery attempt (`...-recovery-01`) exited before generating any new
steps because of the CUDA restore error. It remains archived. The active
continuation is `leo-learning-20261009-01-recovery-02`. The complete regression
suite passed 55 tests, including scheduler boundaries, pending-message resume,
CUDA restore, live-process stall detection and watchdog checkpoint preservation.
`recovery_audit.json` verifies unchanged original checkpoint, Clean status/model,
initial weights, configuration, map and orbital data, plus the new frozen hashes.

Recovery command, after the original verified controller and learner have been
stopped and their diagnostics preserved:

```powershell
.venv\Scripts\python.exe -u scripts\recover_leo_study.py `
  --source output/leo-learning/leo-learning-20261009-01 `
  --run-id leo-learning-20261009-01-recovery-02
```

## Second replay-boundary correction and continuation, October 13

Recovery-02 subsequently stalled at generated step 130,085. The watchdog
stopped it after 602 seconds without progress and preserved the 125,000-step
checkpoint (1,928 completed episodes, first two phases qualified). A recorded
bounded reproduction identified the precise cause: at absolute 131,085.05 s,
subtracting six 21,600-second replay periods gives 1,485.0499999999884 s, just
below the local interruption end of 1,485.05 s. Comparing local time then setting
the absolute cursor to the end repeatedly reconstructed the same cursor.

The correction compares both interruption entry and exit in absolute time and
accounts for actual elapsed interruption time there. It preserves the original
interruption duration and replay schedule. Tests cover both sides of interruption
ends, the exact failing timestamp, disabled handovers and replay cycles through
the 80-million-step clock range. All 56 tests pass after this correction.

The authorized continuation is `leo-learning-20261009-01-recovery-03`, resumed
from recovery-02's 125,000-step checkpoint. Its remaining allocation is about
10 hours 37 minutes, including shutdown reserve. The same configuration, random
states, experiences, models, pending traffic and qualified Clean reference are
retained. Only `leo.py` changes relative to recovery-02; earlier code differences
remain documented through the parent recovery lineage. Original post-checkpoint
records remain archived, and the 5,085 later generated steps are recomputed.
