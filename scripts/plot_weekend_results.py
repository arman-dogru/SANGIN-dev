#!/usr/bin/env python3
"""Create PANAMA-style figures from a weekend partial-training run.

Figure curves use only episode keys shared by the compared setups within each
curriculum stage. This keeps the random MAPF tasks aligned while policies and
radio modes differ. Validation curves remain the run's 50-episode greedy checks.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Iterable


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RUN = PROJECT_ROOT / "artifacts" / "runs" / "panama-weekend-v2"
DEFAULT_WORK = PROJECT_ROOT / "tmp" / "pdfs" / "weekend_results"
DEFAULT_PDF = PROJECT_ROOT / "output" / "pdf" / "panama_weekend_results.pdf"

SETUPS = ("setup1_mapf", "setup2_static_aware", "setup4_uav_aware")
LABELS = {
    "setup1_mapf": "Setup 1: MAPF",
    "setup2_static_aware": "Setup 2: static-aware",
    "setup4_uav_aware": "Setup 4: UAV-aware",
}
COLORS = {
    "setup1_mapf": "#4C78A8",
    "setup2_static_aware": "#E45756",
    "setup4_uav_aware": "#59A14F",
}
MARKERS = {
    "setup1_mapf": "o",
    "setup2_static_aware": "s",
    "setup4_uav_aware": "^",
}
STAGE_LABELS = (
    "32-10\n2",
    "32-10\n4",
    "32-10\n6",
    "32-20\n6",
    "32-20\n8",
    "64-10\n8",
    "64-10\n12",
    "64-20\n12",
)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--run-directory", type=Path, default=DEFAULT_RUN)
    result.add_argument("--work-directory", type=Path, default=DEFAULT_WORK)
    result.add_argument("--output", type=Path, default=DEFAULT_PDF)
    mode = result.add_mutually_exclusive_group()
    mode.add_argument("--figures-only", action="store_true")
    mode.add_argument("--pdf-only", action="store_true")
    return result


def _records(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        raise FileNotFoundError(path)
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def load_run(run_directory: Path) -> tuple[dict[str, list[dict[str, Any]]], dict[str, list[dict[str, Any]]]]:
    training: dict[str, list[dict[str, Any]]] = {}
    validation: dict[str, list[dict[str, Any]]] = {}
    for setup in SETUPS:
        directory = run_directory / setup / "seed-42" / "training"
        training[setup] = _records(directory / "training.jsonl")
        validation[setup] = _records(directory / "validation.jsonl")
    return training, validation


def _episode_key(record: dict[str, Any]) -> tuple[int, int]:
    return int(record["actor_id"]), int(record["actor_episode"])


def matched_stage_rows(
    training: dict[str, list[dict[str, Any]]],
    stage: int,
) -> dict[str, list[dict[str, Any]]]:
    compared = SETUPS if stage == 0 else SETUPS[1:]
    indexed = {
        setup: {
            _episode_key(record): record
            for record in training[setup]
            if int(record["stage_index"]) == stage
        }
        for setup in compared
    }
    common = set.intersection(*(set(records) for records in indexed.values()))
    if not common:
        raise ValueError(f"No matched episode keys for stage {stage}")
    return {setup: [records[key] for key in sorted(common)] for setup, records in indexed.items()}


def _mean(values: Iterable[float]) -> float:
    materialized = list(values)
    return sum(materialized) / len(materialized)


def summarize(rows: list[dict[str, Any]]) -> dict[str, float]:
    eligible = sum(float(row.get("service_eligible_agents_total", 0.0)) for row in rows)
    successes = [row for row in rows if bool(row["success"])]
    return {
        "success_pct": 100.0 * sum(bool(row["success"]) for row in rows) / len(rows),
        "completion_pct": 100.0 * _mean(float(row["completion_fraction"]) for row in rows),
        "mean_steps": _mean(float(row["steps"]) for row in rows),
        "astar_efficiency_pct": 100.0
        * _mean(float(row["max_initial_astar_distance"]) / float(row["steps"]) for row in successes),
        "link_db": sum(
            float(row["mean_link_quality_db"]) * float(row.get("service_eligible_agents_total", 0.0))
            for row in rows
        )
        / eligible,
        "blackout_per_1000": 1000.0
        * sum(float(row.get("blackout_agent_steps_total", 0.0)) for row in rows)
        / eligible,
        "blackout_entries_per_1000": 1000.0
        * sum(float(row.get("blackout_entries_total", 0.0)) for row in rows)
        / eligible,
        "eligible": eligible,
        "blackout_raw": sum(float(row.get("blackout_agent_steps_total", 0.0)) for row in rows),
    }


def stage_summaries(training: dict[str, list[dict[str, Any]]]) -> dict[str, dict[int, dict[str, float]]]:
    result = {setup: {} for setup in SETUPS}
    for stage in range(len(STAGE_LABELS)):
        for setup, rows in matched_stage_rows(training, stage).items():
            result[setup][stage] = summarize(rows)
    return result


def _style_matplotlib() -> None:
    import matplotlib as mpl

    mpl.rcParams.update(
        {
            "font.family": "serif",
            "font.serif": ["Times New Roman", "DejaVu Serif"],
            "font.size": 9.0,
            "axes.labelsize": 9.0,
            "axes.titlesize": 10.0,
            "axes.linewidth": 0.75,
            "xtick.labelsize": 8.0,
            "ytick.labelsize": 8.0,
            "legend.fontsize": 8.0,
            "lines.linewidth": 1.5,
            "lines.markersize": 4.5,
            "savefig.facecolor": "white",
        }
    )


def _finish_axis(axis: Any, letter: str) -> None:
    axis.grid(True, color="#D9D9D9", linestyle="--", linewidth=0.55, alpha=0.8)
    axis.spines["top"].set_visible(False)
    axis.spines["right"].set_visible(False)
    axis.text(-0.13, 1.05, f"({letter})", transform=axis.transAxes, fontweight="bold")


def _legend(figure: Any, axes: Any) -> None:
    handles, labels = axes[0, 0].get_legend_handles_labels()
    figure.legend(
        handles,
        labels,
        loc="upper center",
        bbox_to_anchor=(0.5, 0.925),
        ncol=3,
        frameon=False,
    )


def plot_mapf_page(
    validation: dict[str, list[dict[str, Any]]],
    stages: dict[str, dict[int, dict[str, float]]],
    destination: Path,
) -> None:
    import matplotlib.pyplot as plt

    figure, axes = plt.subplots(2, 2, figsize=(11.0, 8.5))
    figure.suptitle("Weekend partial training: learning and MAPF efficiency", fontsize=14, fontweight="bold", y=0.975)
    figure.text(
        0.5,
        0.941,
        "Seed 42  |  Setup 3 has no training log; it is instantiated only during evaluation",
        ha="center",
        color="#4A4A4A",
        fontsize=8.5,
    )

    for setup in SETUPS:
        records = validation[setup]
        x = [float(row["environment_steps"]) / 1_000_000.0 for row in records]
        axes[0, 0].plot(
            x,
            [100.0 * float(row["success_rate"]) for row in records],
            color=COLORS[setup],
            marker=MARKERS[setup],
            markevery=max(1, len(records) // 12),
            label=LABELS[setup],
        )
        axes[0, 1].plot(
            x,
            [float(row["average_successful_steps"]) for row in records],
            color=COLORS[setup],
            marker=MARKERS[setup],
            markevery=max(1, len(records) // 12),
            label=LABELS[setup],
        )

    axes[0, 0].axhline(90.0, color="#555555", linestyle=":", linewidth=1.0)
    axes[0, 0].text(0.98, 0.88, "90% graduation", transform=axes[0, 0].transAxes, ha="right", fontsize=7.5)
    axes[0, 0].set(title="Greedy inference success", xlabel="Environment steps (millions)", ylabel="Success rate (%)", ylim=(-2, 103))
    _finish_axis(axes[0, 0], "a")

    axes[0, 1].set(title="Greedy inference solution length", xlabel="Environment steps (millions)", ylabel="Average successful steps")
    _finish_axis(axes[0, 1], "b")

    x = list(range(len(STAGE_LABELS)))
    for setup in SETUPS:
        sx = sorted(stages[setup])
        axes[1, 0].plot(
            sx,
            [stages[setup][stage]["success_pct"] for stage in sx],
            color=COLORS[setup],
            marker=MARKERS[setup],
            label=LABELS[setup],
        )
        axes[1, 1].plot(
            sx,
            [stages[setup][stage]["astar_efficiency_pct"] for stage in sx],
            color=COLORS[setup],
            marker=MARKERS[setup],
            label=LABELS[setup],
        )

    axes[1, 0].set(title="Matched training-rollout success", xlabel="Map size-obstacle density / agents", ylabel="Success rate (%)", xticks=x, xticklabels=STAGE_LABELS, ylim=(-2, 103))
    _finish_axis(axes[1, 0], "c")
    axes[1, 1].set(title="Successful-path efficiency", xlabel="Map size-obstacle density / agents", ylabel="Initial A* lower bound / makespan (%)", xticks=x, xticklabels=STAGE_LABELS, ylim=(0, 100))
    _finish_axis(axes[1, 1], "d")

    _legend(figure, axes)
    figure.text(
        0.5,
        0.018,
        "Fig. 1. Panels (a,b): 50-episode greedy validation checks. Panels (c,d): episode-matched training rollouts; exploration decays to 0.1.",
        ha="center",
        fontsize=8.0,
    )
    figure.tight_layout(rect=(0.045, 0.055, 0.985, 0.91), h_pad=2.0, w_pad=2.0)
    figure.savefig(destination, dpi=220)
    plt.close(figure)


def plot_network_page(stages: dict[str, dict[int, dict[str, float]]], destination: Path) -> None:
    import matplotlib.pyplot as plt

    figure, axes = plt.subplots(2, 2, figsize=(11.0, 8.5))
    figure.suptitle("Weekend partial training: link quality and blackout trade-offs", fontsize=14, fontweight="bold", y=0.975)
    figure.text(
        0.5,
        0.941,
        "Episode-matched tasks  |  Service population ends at each agent's first goal arrival",
        ha="center",
        color="#4A4A4A",
        fontsize=8.5,
    )
    x = list(range(len(STAGE_LABELS)))
    for setup in SETUPS:
        sx = sorted(stages[setup])
        axes[0, 0].plot(sx, [stages[setup][stage]["link_db"] for stage in sx], color=COLORS[setup], marker=MARKERS[setup], label=LABELS[setup])
        axes[0, 1].plot(sx, [stages[setup][stage]["blackout_per_1000"] for stage in sx], color=COLORS[setup], marker=MARKERS[setup], label=LABELS[setup])
        axes[1, 0].plot(sx, [stages[setup][stage]["blackout_entries_per_1000"] for stage in sx], color=COLORS[setup], marker=MARKERS[setup], label=LABELS[setup])

    axes[0, 0].axhline(-8.47, color="#555555", linestyle=":", linewidth=1.0)
    axes[0, 0].text(0.98, 0.05, "Blackout threshold: -8.47 dB", transform=axes[0, 0].transAxes, ha="right", fontsize=7.5)
    axes[0, 0].set(title="Mean service link quality", xlabel="Map size-obstacle density / agents", ylabel="Link quality (dB)", xticks=x, xticklabels=STAGE_LABELS)
    _finish_axis(axes[0, 0], "a")

    axes[0, 1].set(title="Blackout exposure", xlabel="Map size-obstacle density / agents", ylabel="Blackout agent-steps per 1,000", xticks=x, xticklabels=STAGE_LABELS)
    axes[0, 1].set_ylim(bottom=0)
    _finish_axis(axes[0, 1], "b")

    axes[1, 0].set(title="Blackout transitions", xlabel="Map size-obstacle density / agents", ylabel="Blackout entries per 1,000 service steps", xticks=x, xticklabels=STAGE_LABELS)
    axes[1, 0].set_ylim(bottom=0)
    _finish_axis(axes[1, 0], "c")

    for setup in SETUPS[1:]:
        for stage in (5, 6, 7):
            value = stages[setup][stage]
            axes[1, 1].scatter(
                value["blackout_per_1000"] / 10.0,
                value["mean_steps"],
                color=COLORS[setup],
                marker=MARKERS[setup],
                s=45,
                zorder=3,
                label=LABELS[setup] if stage == 5 else None,
            )
            axes[1, 1].annotate(
                f"S{stage}",
                (value["blackout_per_1000"] / 10.0, value["mean_steps"]),
                xytext=(5, 4),
                textcoords="offset points",
                fontsize=7.5,
            )
        axes[1, 1].plot(
            [stages[setup][stage]["blackout_per_1000"] / 10.0 for stage in (5, 6, 7)],
            [stages[setup][stage]["mean_steps"] for stage in (5, 6, 7)],
            color=COLORS[setup],
            alpha=0.55,
            linewidth=1.0,
        )
    axes[1, 1].set(title="Large-map makespan vs blackout", xlabel="Blackout service steps (%)", ylabel="Mean episode steps")
    _finish_axis(axes[1, 1], "d")

    _legend(figure, axes)
    stage0 = {setup: stages[setup][0] for setup in SETUPS}
    figure.text(
        0.5,
        0.034,
        "Matched stage-0 raw blackout agent-steps: "
        + "  |  ".join(f"{LABELS[setup].split(':')[0]} {stage0[setup]['blackout_raw']:,.0f}" for setup in SETUPS),
        ha="center",
        fontsize=7.8,
    )
    figure.text(
        0.5,
        0.015,
        "Fig. 2. Setups 1/2 report terrestrial SINR; Setup 4 reports aerial effective SNR/link margin. Compare blackout rates across radio models.",
        ha="center",
        fontsize=8.0,
    )
    figure.tight_layout(rect=(0.045, 0.065, 0.985, 0.91), h_pad=2.0, w_pad=2.0)
    figure.savefig(destination, dpi=220)
    plt.close(figure)


def render_figures(run_directory: Path, work_directory: Path) -> list[Path]:
    _style_matplotlib()
    training, validation = load_run(run_directory)
    stages = stage_summaries(training)
    work_directory.mkdir(parents=True, exist_ok=True)
    pages = [work_directory / "mapf_metrics.png", work_directory / "network_metrics.png"]
    plot_mapf_page(validation, stages, pages[0])
    plot_network_page(stages, pages[1])
    return pages


def compose_pdf(pages: list[Path], destination: Path) -> None:
    from reportlab.lib.pagesizes import landscape, letter
    from reportlab.pdfgen import canvas

    destination.parent.mkdir(parents=True, exist_ok=True)
    width, height = landscape(letter)
    document = canvas.Canvas(str(destination), pagesize=(width, height), pageCompression=1)
    document.setTitle("PANAMA weekend partial-training results")
    document.setAuthor("PANAMA UAV experiment")
    document.setSubject("MAPF efficiency, SNR/link quality, and blackout analysis")
    for page in pages:
        if not page.is_file():
            raise FileNotFoundError(page)
        document.drawImage(str(page), 0, 0, width=width, height=height, preserveAspectRatio=True, mask="auto")
        document.showPage()
    document.save()


def main() -> int:
    args = parser().parse_args()
    pages = [args.work_directory / "mapf_metrics.png", args.work_directory / "network_metrics.png"]
    if not args.pdf_only:
        pages = render_figures(args.run_directory.resolve(), args.work_directory.resolve())
    if not args.figures_only:
        compose_pdf(pages, args.output.resolve())
        print(args.output.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
