# Completed LEO learning results

Both conditions qualified all four curriculum stages using 200-case greedy validation batches.

| Metric | Perfect communication | LEO learning transport |
|---|---:|---:|
| Completed training episodes | 8,500 | 10,000 |
| Generated environment steps | 502,968 | 559,456 |
| Recorded run time | 5 h 35 min | 10 h 54 min |

The LEO arm used 11.23% more generated steps and 17.65% more episodes in this matched seed-42 comparison. Stage 3 required 2,500 episodes rather than 1,250. Both arms' qualifying final-stage success rates were 95% (190/200).

The same curriculum validation cases are reused at each check. Validation uses the current cloud learner greedily with fresh mission information and perfect communication. These are learning-transport results, not frozen-policy mission-inference delay tests. One matched seed does not establish across-seed uncertainty.

Recorded run time includes training, validation, checkpointing and transport-simulator CPU overhead; infrastructure hangs and recovery downtime are excluded. The runtime ratio is not a pure radio-delay effect.

## Figures and data

Open index.html in a browser for the complete gallery. Every figure has PNG, PDF and SVG versions. Labels use Stage 1 through Stage 4 without map names or agent counts.

Training success lines use trailing 100-episode means, and dots are 200-case greedy validations. Successful makespan excludes failed episodes; the separate PAR-2 figures assign 500 steps to each failed 250-step episode.

Complete-message latency statistics use every delivered experience and robot-bound complete model in transport.jsonl. Model latency includes the full publication-to-robot delivery, while deployed-model age also includes the 16-step publication interval. Nine messages remain pending at final qualification and are not counted as delivered. Stage attribution uses message generation time.

Learning-transport curves use seed-42 stratified observations (avoiding aliasing with the publication interval) and trailing 50-observation means. The sampled CSV files contain the unsmoothed measured values. No curves are extrapolated or synthetically extended.

- stage_results.csv: per-stage episodes, generated steps, recorded time and qualifying validation outcomes.
- run_totals.csv: complete measured training totals.
- message_delivery_summary.csv: counts and exact mean/median/p95/max delivery ages.
- clean_telemetry_sample.csv and combined_telemetry_sample.csv: actual sampled step records.
- results.json: audit counts, source-file hashes, interpretation notes, recovery lineage and all numerical summaries.

The original JSONL records remain in the clean/ and combined/ folders one level above this report. They are not duplicated in the archive because of their size. Source hashes and recovery history are retained in results.json.

## Editable plotting script

The authoritative script is scripts/plot_leo_results.py in the repository; an identical copy is included here. Edit COLORS, WINDOW, TELEMETRY_WINDOW, STYLE and plotting functions.

Run from the repository:

```powershell
.venv\Scripts\python.exe scripts/plot_leo_results.py --root output/leo-learning/leo-learning-20261009-01-recovery-03
```

When changing only appearance, reuse the exact prior message summaries after source-hash verification:

```powershell
.venv\Scripts\python.exe scripts/plot_leo_results.py --root output/leo-learning/leo-learning-20261009-01-recovery-03 --reuse-delivery-summary
```
