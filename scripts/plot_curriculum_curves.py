"""Plot episode curves by curriculum stage, plus a local browsable figure gallery."""
from __future__ import annotations

import argparse
from collections import defaultdict
import csv
import html
import json
import math
import os
from pathlib import Path
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from panama_uav.config import load_config

LABELS = {
    "setup1_mapf": "MAPF + STATIC UNAWARE",
    "setup2_static_aware": "MAPF + STATIC AWARE",
    "setup3_uav_unaware": "MAPF + UAV UNAWARE",
    "setup4_uav_aware": "MAPF + UAV AWARE",
}
COLORS = {
    "setup1_mapf": "#3366a6",
    "setup2_static_aware": "#dc7b20",
    "setup3_uav_unaware": "#27906b",
    "setup4_uav_aware": "#9349b5",
}
PHASES = {"training": "Training episodes", "validation": "Validation during training", "test": "Fixed-policy curriculum tests"}
# key, label, axis label, scale, bounds
METRICS = [
    ("success_rate", "Success rate", "Success (%)", 100.0, (0, 100)),
    ("completion_fraction", "Agent completion", "Completed agents (%)", 100.0, (0, 100)),
    ("mean_link_quality_db", "Mean received SNR / SINR", "Received link quality (dB)", 1.0, None),
    ("p05_link_quality_db", "P05 received SNR / SINR", "P05 link quality (dB)", 1.0, None),
    ("blackout_entries", "Blackout events per episode", "Blackout onsets / episode", 1.0, None),
    ("blackout_entries_per_1000", "Normalized blackout events", "Onsets / 1,000 eligible steps", 1.0, None),
    ("blackout_agent_steps_per_1000", "Blackout duration", "Outage agent-steps / 1,000 eligible steps", 1.0, (0, 1000)),
    ("network_service_rate", "Network service rate", "Eligible agent-steps served (%)", 100.0, (0, 100)),
    ("uav_distance_m", "UAV distance per episode", "UAV distance (m / episode)", 1.0, None),
    ("uav_distance_per_step_m", "UAV distance per step", "UAV distance (m / simulation step)", 1.0, None),
    ("uav_move_step_rate", "UAV moving-step rate", "Steps with UAV movement (%)", 100.0, (0, 100)),
    ("par2_steps", "Failure-aware solution length", "PAR-2 steps", 1.0, None),
]


def read_jsonl(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def numeric(value) -> float:
    return float(value) if value is not None else math.nan


def canonical(record: dict, phase: str, setup: str, seed: int) -> dict:
    result = {
        "phase": phase, "setup": setup, "training_seed": seed,
        "stage_index": int(record["stage_index"]), "stage_name": record["stage_name"],
        "episode": int(record["test_episode"] if phase == "test" else record["stage_episode"]),
        "global_episode": record.get("global_episode"),
        "episode_seed": record.get("episode_seed"),
        "scenario": record.get("scenario"),
        "link_quality_kind": record.get("link_quality_kind", "effective_snr" if "uav" in setup else "sinr"),
    }
    if phase == "validation":
        mapping = {
            "completion_fraction": "average_completion_fraction",
            "uav_distance_m": "average_uav_distance_m",
            "uav_distance_per_step_m": "average_uav_distance_per_step_m",
            "uav_move_step_rate": "average_uav_move_step_rate",
            "par2_steps": "average_par2_steps",
        }
        for metric, *_ in METRICS:
            result[metric] = numeric(record.get(mapping.get(metric, metric)))
    else:
        for metric, *_ in METRICS:
            if metric == "success_rate":
                value = float(record["success"])
            elif metric == "blackout_entries" and phase == "training":
                # Sparse step counters omit a key when its count is zero.
                value = record.get("blackout_entries_total", 0)
            else:
                value = record.get(metric)
            result[metric] = numeric(value)
    if "uav" not in setup:
        for metric in ("uav_distance_m", "uav_distance_per_step_m", "uav_move_step_rate"):
            result[metric] = 0.0
    return result


def load_records(root: Path) -> list[dict]:
    records = []
    for setup in LABELS:
        for directory in sorted((root / setup).glob("seed-*")):
            seed = int(directory.name.split("-", 1)[1])
            for phase, name in (("training", "training.jsonl"), ("validation", "validation.jsonl")):
                records.extend(canonical(record, phase, setup, seed) for record in read_jsonl(directory / "training" / name))
    for record in read_jsonl(root / "curriculum_tests" / "episodes.jsonl"):
        records.append(canonical(record, "test", record["setup"], int(record["training_seed"])))
    return records


def rolling(values: np.ndarray, window: int) -> np.ndarray:
    finite = np.isfinite(values)
    totals = np.r_[0.0, np.cumsum(np.where(finite, values, 0.0))]
    counts = np.r_[0, np.cumsum(finite)]
    end = np.arange(1, len(values) + 1)
    start = np.maximum(0, end - window)
    total = totals[end] - totals[start]
    count = counts[end] - counts[start]
    return np.divide(total, count, out=np.full(len(values), np.nan), where=count > 0)


def note(phase: str, metric: str, training_window: int, test_window: int, validation_episodes: int) -> str:
    if phase == "training":
        text = f"Trailing {training_window}-episode mean within each stage; partial windows at stage start. Exploration remains active."
    elif phase == "validation":
        text = f"Each marker summarizes {validation_episodes} validation episodes; x is the training episode when the policy was tested."
    else:
        text = f"Trailing {test_window}-case mean; faint points are individual episodes. Frozen best policies; no learning during tests."
    if phase == "test" and metric == "success_rate_cumulative":
        text = "Cumulative success among cases tested so far; faint points are individual episode outcomes. Frozen best policies; no learning during tests."
    if "link_quality" in metric:
        text += " Static = SINR; UAV = effective SNR. Compare dB within infrastructure pairs."
    if "uav_" in metric:
        text += " Static curves are zero (no UAV). UAV-unaware motion was not recorded during training."
    if phase != "test":
        text += " UAV-unaware shares the static-unaware policy; it has no independent training/validation log."
    if metric == "blackout_entries":
        text += " Includes initial blackout plus later onsets. Raw counts were not saved in validation summaries."
    return text


def stage_title(stage, index: int) -> str:
    name = Path(stage.map_path).stem.replace("random-", "")
    return f"Stage {index}: {name} | {stage.num_agents} agents"


def draw_stage(ax, grouped: dict, phase: str, index: int, metric: tuple, window: int, show_gaps: bool = True):
    field, _, ylabel, scale, bounds = metric
    missing = []
    for setup in LABELS:
        groups = [(seed, values) for (p, stage, s, seed), values in grouped.items() if p == phase and stage == index and s == setup]
        shared = False
        # Task success/completion in Setup 3 belongs to the exact reused policy.
        # No historical UAV link or motion values are fabricated.
        if not groups and setup == "setup3_uav_unaware" and phase != "test" and field in {"success_rate", "completion_fraction", "par2_steps"}:
            groups = [(seed, values) for (p, stage, s, seed), values in grouped.items() if p == phase and stage == index and s == "setup1_mapf"]
            shared = bool(groups)
        found = False
        for seed, records in groups:
            x = np.array([record["episode"] for record in records], dtype=float)
            y = np.array([record["success_rate" if field == "success_rate_cumulative" else field] for record in records], dtype=float) * scale
            if not np.isfinite(y).any():
                continue
            found = True
            if phase == "test":
                ax.scatter(x, y, s=12, color=COLORS[setup], alpha=0.16, linewidths=0, zorder=1)
            if field == "success_rate_cumulative":
                smoothed = rolling(y, len(y))
            else:
                smoothed = y if phase == "validation" else rolling(y, window)
            thinning = max(1, len(x) // 1600)
            selection = np.unique(np.r_[np.arange(0, len(x), thinning), len(x)-1])
            linestyle = "--" if setup == "setup3_uav_unaware" else "-"
            linewidth = 3.4 if setup == "setup1_mapf" and field in {"success_rate", "completion_fraction", "par2_steps"} else 1.8
            ax.plot(x[selection], smoothed[selection], color=COLORS[setup], linestyle=linestyle,
                    linewidth=linewidth, marker="o" if phase == "validation" else None,
                    markersize=3, alpha=0.90, zorder=3 if shared else 2)
        if not found:
            missing.append(setup)
    if show_gaps and missing:
        if missing == ["setup3_uav_unaware"]:
            message = "UAV unaware: no independent log"
        else:
            short = {"setup1_mapf": "static unaware", "setup2_static_aware": "static aware", "setup3_uav_unaware": "UAV unaware", "setup4_uav_aware": "UAV aware"}
            message = "No data: " + ", ".join(short[setup] for setup in missing)
        ax.text(0.02, 0.03, message, transform=ax.transAxes, fontsize=7.3, color="#555555",
                bbox={"facecolor": "white", "alpha": .8, "edgecolor": "none", "pad": 2})
    ax.set_ylabel(ylabel, fontsize=9)
    ax.set_xlabel("Training episode within stage" if phase != "test" else "Test episode within stage", fontsize=9)
    ax.grid(alpha=.22, linewidth=.6)
    ax.tick_params(labelsize=8)
    ax.ticklabel_format(axis="x", style="plain", useOffset=False)


def make_metric_grid(destination: Path, config, grouped: dict, phase: str, metric: tuple, args) -> None:
    import matplotlib.pyplot as plt
    from matplotlib.lines import Line2D
    fig, axes = plt.subplots(2, 4, figsize=(18, 8.5), sharey=True)
    fig.subplots_adjust(left=.055, right=.99, top=.78, bottom=.18, wspace=.30, hspace=.52)
    window = args.training_window if phase == "training" else args.test_window
    for index, stage in enumerate(config.curriculum):
        ax = axes.flat[index]
        draw_stage(ax, grouped, phase, index, metric, window)
        ax.set_title(stage_title(stage, index), loc="left", fontsize=10, fontweight="bold")
    # Set a common scale only after every stage has contributed its data.
    # Setting one axis limit early disables autoscaling for all shared axes.
    finite_values = []
    for ax in axes.flat:
        for line in ax.lines:
            values = np.asarray(line.get_ydata(), dtype=float)
            finite_values.extend(values[np.isfinite(values)].tolist())
        for collection in ax.collections:
            offsets = np.asarray(collection.get_offsets(), dtype=float)
            if offsets.size:
                values = offsets[:, 1]
                finite_values.extend(values[np.isfinite(values)].tolist())
    bounds = metric[4]
    if bounds:
        axes.flat[0].set_ylim(bounds[0], bounds[1] * 1.035)
    elif finite_values:
        low, high = min(finite_values), max(finite_values)
        if "link_quality" in metric[0]:
            pad = max((high-low)*.07, .5)
            axes.flat[0].set_ylim(low-pad, high+pad)
        else:
            axes.flat[0].set_ylim(0, max(high*1.07, 1.0))
    else:
        axes.flat[0].set_ylim(0, 1)
    handles = [Line2D([0], [0], color=COLORS[setup], linewidth=2.3, linestyle="--" if setup == "setup3_uav_unaware" else "-", label=label) for setup, label in LABELS.items()]
    fig.legend(handles=handles, loc="upper center", bbox_to_anchor=(.52,.885), ncol=4, frameon=False, fontsize=10)
    fig.suptitle(f"{PHASES[phase]} — {metric[1]}", fontsize=20, fontweight="bold", y=.965)
    import textwrap
    caption = note(phase, metric[0], args.training_window, args.test_window, config.training.validation_episodes)
    fig.text(.055,.065,"\n".join(textwrap.wrap(caption, 155)), fontsize=10, color="#444444", va="bottom")
    target = destination / f"{phase}__{metric[0]}"
    fig.savefig(target.with_suffix(".png"), dpi=160, facecolor="white")
    fig.savefig(target.with_suffix(".pdf"), facecolor="white")
    plt.close(fig)


def write_csv(path: Path, records: list[dict]) -> None:
    fields = ["phase", "setup", "training_seed", "stage_index", "stage_name", "episode", "global_episode", "episode_seed", "scenario", "link_quality_kind"] + [metric[0] for metric in METRICS]
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for record in records:
            writer.writerow({key: "" if isinstance(value, float) and math.isnan(value) else value for key, value in record.items()})


def write_coverage(path: Path, grouped: dict, config) -> None:
    rows = []
    for phase in PHASES:
        for stage_index, stage in enumerate(config.curriculum):
            for setup in LABELS:
                values = [record for (p, index, s, _), group in grouped.items() if (p,index,s) == (phase,stage_index,setup) for record in group]
                row = {"phase": phase, "stage_index": stage_index, "stage_name": stage.name, "setup": setup, "records": len(values)}
                row.update({metric[0]+"_recorded": sum(math.isfinite(record[metric[0]]) for record in values) for metric in METRICS})
                rows.append(row)
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def write_stage_table(path: Path, records: list[dict], config) -> None:
    lines = ["# Fixed-policy tests at every curriculum stage", "", "All four setups use the same cases, starts, goals, and episode seeds within each stage. Each policy is frozen at its saved best checkpoint; these are new stage tests, separate from the previous final evaluation and the historical validation batches.", "", "| Stage | Map | Agents | Setup | Cases | Success | Mean link dB | P05 link dB | Blackout events/episode | Blackout steps/1k | UAV m/episode | UAV m/step |", "|---:|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for index, stage in enumerate(config.curriculum):
        for setup, label in LABELS.items():
            group = [record for record in records if record["phase"] == "test" and record["stage_index"] == index and record["setup"] == setup]
            if not group:
                continue
            mean = lambda field: float(np.mean([record[field] for record in group]))
            lines.append(f"| {index} | {Path(stage.map_path).stem} | {stage.num_agents} | {label} | {len(group)} | {mean('success_rate'):.1%} | {mean('mean_link_quality_db'):.2f} | {mean('p05_link_quality_db'):.2f} | {mean('blackout_entries'):.2f} | {mean('blackout_agent_steps_per_1000'):.2f} | {mean('uav_distance_m'):.2f} | {mean('uav_distance_per_step_m'):.2f} |")
    lines += ["", "Link-quality entries are episode means; P05 entries average the individual episode P05 values. Static setups measure SINR; UAV setups measure effective SNR. Static UAV distance is zero because no UAV is present."]
    path.write_text("\n".join(lines)+"\n", encoding="utf-8")


def write_gallery(destination: Path, config, args) -> None:
    metric_options = "".join(f'<option value="{metric[0]}">{html.escape(metric[1])}</option>' for metric in METRICS)
    payload = {phase: {metric[0]: note(phase,metric[0],args.training_window,args.test_window,config.training.validation_episodes) for metric in METRICS} for phase in PHASES}
    payload["test"]["success_rate_cumulative"] = note("test", "success_rate_cumulative",args.training_window,args.test_window,config.training.validation_episodes)
    document = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>PANAMA curriculum episode curves</title><style>
    *{box-sizing:border-box}body{margin:0;background:#f3f5f8;color:#192235;font:15px/1.5 system-ui,sans-serif}header{padding:28px 36px;background:#14213a;color:white}h1{margin:0;font-size:26px}header p{max-width:1100px;color:#cbd5e5;margin:10px 0 0}main{padding:24px 32px}.controls{display:flex;gap:12px;align-items:center;flex-wrap:wrap}button,select,a.download{font:inherit;padding:10px 14px;border:1px solid #ced5df;border-radius:6px;background:white;color:#192235;cursor:pointer}button.active{background:#234c88;color:white;border-color:#234c88}select{min-width:270px}.card{margin-top:20px;background:white;border:1px solid #dce1e8;border-radius:8px;overflow:hidden}img{display:block;width:100%;height:auto}.caption{padding:15px 20px;color:#465368;border-top:1px solid #e7ebf0}.links{display:flex;gap:14px;flex-wrap:wrap;padding-top:18px}a{color:#235c9b}.notes{margin-top:22px;max-width:1200px}.notes li{margin-bottom:8px}.download{text-decoration:none}label{font-weight:600}.status{margin:8px 0;color:#5d6980}</style>
    <header><h1>Curriculum progress across episodes</h1><p>Weekend partial training · one training seed · eight curriculum stages · all four setup names are consistent across every plot.</p></header><main>
    <div class="controls"><button data-phase="training" class="active">Training</button><button data-phase="validation">Validation during training</button><button data-phase="test">Curriculum tests</button><label for="metric">Metric</label><select id="metric">OPTIONS</select><label id="cumulative-control" hidden><input type="checkbox" id="cumulative" checked> Cumulative test success</label><a class="download" id="pdf">Download PDF</a><a class="download" id="png">Open PNG</a></div>
    <p class="status">Each panel is one curriculum stage. Episode numbering restarts within each stage.</p><div class="card"><img id="figure" alt="Episode curves for eight curriculum stages"><div id="caption" class="caption"></div></div>
    <div class="links"><a href="episode_metrics.csv">All episode metrics (CSV)</a><a href="data_coverage.csv">Recorded-data coverage (CSV)</a><a href="CURRICULUM_TEST_RESULTS.md">Stage test results</a><a href="README.md">Protocol and interpretation</a></div>
    <div class="notes"><ul><li><b>Training:</b> recorded exploratory episodes, averaged within each stage. Curves stop where a setup stopped training.</li><li><b>Validation:</b> saved policy tests performed during training. Markers use the training episode of each test batch.</li><li><b>Curriculum tests:</b> matched cases at the exact agent count and cap of each stage. The saved best policy stays fixed; changes along this axis are case variation, not learning.</li><li><b>UAV unaware:</b> reuses the static-unaware MAPF policy. Dashed training task curves identify that shared policy. Its historical UAV SNR and movement cannot be recovered because there was no independent training log.</li><li><b>Radio:</b> static SINR and UAV effective SNR use different models; compare dB within the corresponding infrastructure pair.</li><li><b>Blackouts:</b> event onsets and outage agent-steps are separate metrics. Counts include initial outages. Rates exclude completed agents.</li><li><b>UAV movement:</b> compare total episode distance, distance per step, and moving-step rate separately. Static setups have no UAV.</li></ul></div>
    </main><script>const captions=PAYLOAD;let phase='training';const metric=document.getElementById('metric');const cumulative=document.getElementById('cumulative');function update(){const isSuccessTest=phase==='test'&&metric.value==='success_rate';document.getElementById('cumulative-control').hidden=!isSuccessTest;const field=isSuccessTest&&cumulative.checked?'success_rate_cumulative':metric.value;const name=phase+'__'+field;document.getElementById('figure').src=name+'.png';document.getElementById('png').href=name+'.png';document.getElementById('pdf').href=name+'.pdf';document.getElementById('caption').textContent=captions[phase][field];document.querySelectorAll('[data-phase]').forEach(b=>b.classList.toggle('active',b.dataset.phase===phase));}metric.addEventListener('change',update);cumulative.addEventListener('change',update);document.querySelectorAll('[data-phase]').forEach(b=>b.addEventListener('click',()=>{phase=b.dataset.phase;update();}));update();</script></html>'''
    destination.joinpath("index.html").write_text(document.replace("OPTIONS",metric_options).replace("PAYLOAD",json.dumps(payload)),encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_directory", type=Path)
    parser.add_argument("--config", default="configs/panama_comparison.toml")
    parser.add_argument("--training-window", type=int, default=200)
    parser.add_argument("--test-window", type=int, default=5)
    parser.add_argument("--phases", nargs="+", choices=list(PHASES), default=list(PHASES))
    args = parser.parse_args()
    if args.training_window < 1 or args.test_window < 1:
        parser.error("Smoothing windows must be positive")
    config = load_config(args.config)
    if len(config.curriculum) != 8:
        parser.error("This layout expects an eight-stage curriculum")
    root = args.run_directory.resolve()
    test_manifest_path = root / "curriculum_tests" / "manifest.json"
    test_episodes = json.loads(test_manifest_path.read_text(encoding="utf-8"))["episodes_per_stage"] if test_manifest_path.is_file() else "available"
    destination = root / "plots" / "curriculum_episode_curves"
    destination.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("MPLCONFIGDIR", str(root / ".mplconfig"))
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams.update({"font.family":"DejaVu Sans", "axes.spines.top":False,"axes.spines.right":False,"pdf.fonttype":42})
    records = load_records(root)
    if not records:
        raise ValueError("No episode logs found")
    grouped = defaultdict(list)
    for record in records:
        grouped[(record["phase"],record["stage_index"],record["setup"],record["training_seed"])].append(record)
    for group in grouped.values():
        group.sort(key=lambda record: record["episode"])
        if len({record["episode"] for record in group}) != len(group):
            raise ValueError("Duplicate episode numbers in stage/phase/setup/seed group")
    write_csv(destination / "episode_metrics.csv",records)
    write_coverage(destination / "data_coverage.csv",grouped,config)
    write_stage_table(destination / "CURRICULUM_TEST_RESULTS.md",records,config)
    for phase in args.phases:
        for metric in METRICS:
            make_metric_grid(destination,config,grouped,phase,metric,args)
        if phase == "test":
            cumulative_metric = ("success_rate_cumulative", "Cumulative success rate", "Success (%)", 100.0, (0,100))
            make_metric_grid(destination,config,grouped,phase,cumulative_metric,args)
        print(f"Created {phase} figures",flush=True)
    write_gallery(destination,config,args)
    readme = """# Episode curves by curriculum stage

Open `index.html` to select Training, Validation during training, or Curriculum tests and a metric. Every figure has eight stage panels and the four requested setup labels. PNG and vector PDF exports are included.

Training uses a trailing WINDOW_TRAIN-episode mean, resetting at each stage. It records exploratory behavior rather than the greedy policy. Validation markers summarize the original saved validation batches; their x-axis is the training episode at which the batch ran. Curriculum tests use a trailing WINDOW_TEST-case mean and show individual values faintly. Early windows contain the episodes available so far.

The new curriculum test protocol evaluates the frozen best policy from each setup on the same TEST_EPISODES held-out MovingAI cases at each stage's exact agent count and episode cap. It evaluates all eight stages even when a policy did not reach that stage during training. These are descriptive small-sample tests, separate from the earlier 1,200-episode evaluation. The manifest in `../../curriculum_tests/manifest.json` records configuration, checkpoint hashes, scenario hashes, and the fixed-policy protocol. No training was performed to make these figures.

UAV unaware uses the static-unaware checkpoint. Shared training/validation task curves are dashed; historical UAV radio/motion training curves are unavailable. Missing stages are explicitly labeled. Static setups have zero UAV movement because they contain no UAV. Raw validation blackout event counts were not logged, so that panel shows missing data; normalized validation event rates are available.

Mean and P05 link quality include only unfinished-agent service timesteps. Static models report SINR; UAV models report effective SNR. Mean received SNR is not a task metric. Compare radio dB within infrastructure pairs. Blackout events count initial outages and later onsets; normalized duration measures blackout agent-steps per 1,000 eligible agent-steps. Total UAV travel can decrease simply because an episode finishes earlier; distance per step and moving-step rate expose that distinction.

`episode_metrics.csv` contains the underlying scalar measurements. `data_coverage.csv` lists availability by phase, stage, setup and metric. `CURRICULUM_TEST_RESULTS.md` gives new stage test averages. Validation rates are checkpoint-level batch summaries, not per-validation-episode logs; no intermediate validation episodes are invented.

Rebuild:

```powershell
python scripts/evaluate_curriculum_curves.py 'RUN_DIRECTORY' --episodes-per-stage 25 --device cpu
python scripts/plot_curriculum_curves.py 'RUN_DIRECTORY'
python scripts/preview_curriculum_curves.py 'RUN_DIRECTORY' --port 8875
```
"""
    destination.joinpath("README.md").write_text(readme.replace("WINDOW_TRAIN",str(args.training_window)).replace("WINDOW_TEST",str(args.test_window)).replace("TEST_EPISODES",str(test_episodes)).replace("RUN_DIRECTORY",str(root)),encoding="utf-8")
    print(destination / "index.html",flush=True)


if __name__ == "__main__":
    main()
