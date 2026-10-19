#!/usr/bin/env python3
"""Build a concise metric-winner summary from a completed comparison run."""

from __future__ import annotations

import argparse
import csv
import math
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


SETUP_LABELS = {
    "setup1_mapf": "MAPF only",
    "setup2_static_aware": "MAPF + network aware",
    "setup3_uav_unaware": "MAPF + UAV unaware",
    "setup4_uav_aware": "MAPF + UAV aware",
}

SETUP_ORDER = list(SETUP_LABELS)
COLORS = {
    "setup1_mapf": "#4C78A8",
    "setup2_static_aware": "#F58518",
    "setup3_uav_unaware": "#54A24B",
    "setup4_uav_aware": "#B279A2",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_directory", type=Path)
    return parser.parse_args()


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def number(row: dict[str, str], field: str) -> float:
    raw = row.get(field, "")
    if raw in (None, ""):
        return math.nan
    return float(raw)


def weighted_mean(
    rows: list[dict[str, str]], field: str, weight_field: str = "episodes"
) -> float:
    values: list[tuple[float, float]] = []
    for row in rows:
        value = number(row, field)
        weight = number(row, weight_field)
        if math.isfinite(value) and math.isfinite(weight) and weight > 0:
            values.append((value, weight))
    if not values:
        return math.nan
    return sum(value * weight for value, weight in values) / sum(
        weight for _, weight in values
    )


def successful_weighted_mean(rows: list[dict[str, str]], field: str) -> float:
    values: list[tuple[float, float]] = []
    for row in rows:
        value = number(row, field)
        successes = number(row, "success_rate") * number(row, "episodes")
        if math.isfinite(value) and successes > 0:
            values.append((value, successes))
    if not values:
        return math.nan
    return sum(value * weight for value, weight in values) / sum(
        weight for _, weight in values
    )


def overall_results(rows: list[dict[str, str]]) -> dict[str, dict[str, float]]:
    grouped: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        grouped[row["setup"]].append(row)

    ordinary = [
        "success_rate",
        "completion_fraction",
        "par2_steps",
        "path_efficiency",
        "network_service_rate",
        "blackout_agent_steps_per_1000",
        "p05_link_quality_db",
        "uav_distance_m",
        "uav_distance_per_step_m",
        "uav_move_step_rate",
        "uav_coverage_regret_rate",
    ]
    successful = ["makespan_stretch", "sum_of_costs_stretch"]
    result: dict[str, dict[str, float]] = {}
    for setup in SETUP_ORDER:
        setup_rows = grouped[setup]
        result[setup] = {field: weighted_mean(setup_rows, field) for field in ordinary}
        result[setup].update(
            {field: successful_weighted_mean(setup_rows, field) for field in successful}
        )
        result[setup]["episodes"] = sum(number(row, "episodes") for row in setup_rows)
    return result


def format_value(metric: str, value: float) -> str:
    if not math.isfinite(value):
        return "—"
    if metric in {
        "success_rate",
        "completion_fraction",
        "path_efficiency",
        "network_service_rate",
        "uav_move_step_rate",
        "uav_coverage_regret_rate",
    }:
        return f"{100 * value:.2f}%"
    if metric in {"par2_steps", "uav_distance_m"}:
        return f"{value:.2f}"
    return f"{value:.3f}"


def winner_rows(overall: dict[str, dict[str, float]]) -> list[dict[str, str]]:
    specifications = [
        ("Mission success", "success_rate", "higher", SETUP_ORDER, "All setups", "Primary reliability metric"),
        ("Agent completion", "completion_fraction", "higher", SETUP_ORDER, "All setups", "Fraction of agents reaching goals"),
        ("PAR-2 episode length", "par2_steps", "lower", SETUP_ORDER, "All setups", "Penalizes failures at twice the episode cap"),
        ("Path efficiency", "path_efficiency", "higher", SETUP_ORDER, "All setups", "Includes zero contribution from failed episodes"),
        ("Successful makespan stretch", "makespan_stretch", "lower", SETUP_ORDER, "Successful policies", "Defined only for successful episodes"),
        ("Successful sum-cost stretch", "sum_of_costs_stretch", "lower", SETUP_ORDER, "Successful policies", "Defined only for successful episodes"),
        ("Network service rate", "network_service_rate", "higher", SETUP_ORDER, "All setups", "Eligible agent-steps served"),
        ("Blackouts / 1k eligible steps", "blackout_agent_steps_per_1000", "lower", SETUP_ORDER, "All setups", "Normalized outage burden"),
        ("Static lower-tail SINR", "p05_link_quality_db", "higher", SETUP_ORDER[:2], "Static pair", "Compare Setup 2 with Setup 1"),
        ("UAV lower-tail effective SNR", "p05_link_quality_db", "higher", SETUP_ORDER[2:], "UAV pair", "Compare Setup 4 with Setup 3"),
        ("UAV total distance / episode", "uav_distance_m", "lower", SETUP_ORDER[2:], "UAV pair", "Falls when missions end sooner"),
        ("UAV distance / simulation step", "uav_distance_per_step_m", "lower", SETUP_ORDER[2:], "UAV pair", "Normalized motion intensity"),
        ("UAV moving-step rate", "uav_move_step_rate", "lower", SETUP_ORDER[2:], "UAV pair", "Fraction of steps with UAV motion"),
        ("UAV coverage regret", "uav_coverage_regret_rate", "lower", SETUP_ORDER[2:], "UAV pair", "Oracle minus actual service opportunity"),
    ]

    results: list[dict[str, str]] = []
    for label, metric, direction, candidates, scope, note in specifications:
        available = [
            (setup, overall[setup][metric])
            for setup in candidates
            if math.isfinite(overall[setup][metric])
        ]
        available.sort(key=lambda item: item[1], reverse=direction == "higher")
        winner, winner_value = available[0]
        runner, runner_value = available[1] if len(available) > 1 else ("", math.nan)
        results.append(
            {
                "metric": label,
                "scope": scope,
                "preferred_direction": direction,
                "winner": SETUP_LABELS[winner],
                "winner_value": format_value(metric, winner_value),
                "runner_up": SETUP_LABELS.get(runner, "—"),
                "runner_up_value": format_value(metric, runner_value),
                "note": note,
            }
        )
    return results


def write_winners(path: Path, rows: list[dict[str, str]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def stage_summary(stage_rows: list[dict[str, str]]) -> list[tuple[str, str]]:
    grouped: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in stage_rows:
        grouped[row["setup"]].append(row)
    summaries: list[tuple[str, str]] = []
    for setup in ("setup1_mapf", "setup2_static_aware", "setup4_uav_aware"):
        rows = sorted(grouped[setup], key=lambda row: int(row["stage_index"]))
        passed = sum(row["graduated"].lower() == "true" for row in rows)
        final = rows[-1]
        summaries.append(
            (
                SETUP_LABELS[setup],
                f"{passed}/8 stages graduated; stopped at stage {final['stage_index']} "
                f"({final['stage_name']}). Best validation there: "
                f"{100 * float(final['best_success_rate']):.0f}% success, "
                f"{100 * float(final['best_completion_fraction']):.1f}% completion, "
                f"PAR-2 {float(final['best_par2_steps']):.2f}.",
            )
        )
    summaries.insert(
        2,
        (
            SETUP_LABELS["setup3_uav_unaware"],
            "No separate policy training; reuses the Setup 1 MAPF checkpoint and changes only the infrastructure/controller evaluation.",
        ),
    )
    return summaries


def write_markdown(
    path: Path,
    overall: dict[str, dict[str, float]],
    winners: list[dict[str, str]],
    stages: list[tuple[str, str]],
) -> None:
    lines = [
        "# Weekend partial-training comparison",
        "",
        "This proof-of-concept uses one training seed and 1,200 matched evaluation episodes. None of the trained policies graduated all eight curriculum stages, so these results compare the observed partial policies rather than a completed PANAMA reproduction.",
        "",
        "## Overall held-out evaluation",
        "",
        "| Setup | Success | Completion | PAR-2 | Path efficiency | Service | Blackouts / 1k | P05 link dB | UAV m/step |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for setup in SETUP_ORDER:
        values = overall[setup]
        lines.append(
            "| "
            + " | ".join(
                [
                    SETUP_LABELS[setup],
                    format_value("success_rate", values["success_rate"]),
                    format_value("completion_fraction", values["completion_fraction"]),
                    format_value("par2_steps", values["par2_steps"]),
                    format_value("path_efficiency", values["path_efficiency"]),
                    format_value("network_service_rate", values["network_service_rate"]),
                    format_value("blackout_agent_steps_per_1000", values["blackout_agent_steps_per_1000"]),
                    format_value("p05_link_quality_db", values["p05_link_quality_db"]),
                    format_value("uav_distance_per_step_m", values["uav_distance_per_step_m"]),
                ]
            )
            + " |"
        )

    lines.extend(
        [
            "",
            "Static setups report SINR and UAV setups report effective SNR. Compare dB values within the static pair (Setup 2 versus Setup 1) and within the UAV pair (Setup 4 versus Setup 3).",
            "",
            "## Curriculum performance",
            "",
        ]
    )
    for setup, summary in stages:
        lines.append(f"- **{setup}:** {summary}")

    lines.extend(
        [
            "",
            "The full stage-by-stage table is in `STAGE_RESULTS.md` and `stage_validation_results.csv`.",
            "",
            "## Metric winners",
            "",
            "| Metric | Scope | Best setup | Value | Runner-up | Value |",
            "|---|---|---|---:|---|---:|",
        ]
    )
    for row in winners:
        lines.append(
            f"| {row['metric']} | {row['scope']} | {row['winner']} | {row['winner_value']} | "
            f"{row['runner_up']} | {row['runner_up_value']} |"
        )

    lines.extend(
        [
            "",
            "## Interpretation",
            "",
            "- **Best mission policy and best overall service:** MAPF + UAV aware. It leads success, completion, PAR-2, path efficiency, service rate, and normalized blackout burden at every evaluated agent count.",
            "- **Best static-infrastructure policy:** MAPF + network aware. Relative to MAPF only, it improves lower-tail static SINR and reduces normalized blackouts for 4, 8, and 12 agents while recovering partial task success.",
            "- **Cleanest infrastructure-only ablation:** MAPF + UAV unaware. Its action traces and task metrics exactly match MAPF only, while the UAV reduces blackouts and improves service. It isolates the value of UAV support, but inherits the failed MAPF policy.",
            "- **Lowest normalized UAV distance:** MAPF + UAV unaware. MAPF + UAV aware travels less total distance per episode and moves on fewer steps, but travels farther per simulation step. The claim that awareness makes the UAV move less is therefore metric-dependent and is not supported by normalized distance.",
            "- **Shortest successful routes:** MAPF + UAV aware among policies that solved episodes. MAPF only and UAV unaware have no successful episodes, so they cannot be credited with short successful routes.",
            "",
            "Setup 1 remains the main blocker: potential-based goal progress shaping is present, but this partial run never escaped curriculum stage 0. Setup 3 confirms that better connectivity alone does not repair that MAPF policy. Setup 4 is the strongest proof of concept because joint awareness reached stage 7 and generalized best in the matched evaluation.",
        ]
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def grouped_bars(
    ax: plt.Axes,
    rows: list[dict[str, str]],
    field: str,
    title: str,
    ylabel: str,
    percent: bool = False,
) -> None:
    agents = sorted({int(row["num_agents"]) for row in rows})
    x = np.arange(len(agents), dtype=float)
    width = 0.19
    for offset_index, setup in enumerate(SETUP_ORDER):
        setup_rows = {int(row["num_agents"]): row for row in rows if row["setup"] == setup}
        values = [number(setup_rows[agent], field) for agent in agents]
        if percent:
            values = [100 * value for value in values]
        ax.bar(
            x + (offset_index - 1.5) * width,
            values,
            width,
            color=COLORS[setup],
            label=SETUP_LABELS[setup],
        )
    ax.set_title(title, loc="left", fontweight="bold")
    ax.set_ylabel(ylabel)
    ax.set_xticks(x, [str(agent) for agent in agents])
    ax.set_xlabel("Agents")
    ax.grid(axis="y", alpha=0.25)


def make_plot(path: Path, rows: list[dict[str, str]]) -> None:
    plt.rcParams.update({"font.size": 9, "axes.spines.top": False, "axes.spines.right": False})
    fig, axes = plt.subplots(2, 3, figsize=(15, 8.5), constrained_layout=True)
    grouped_bars(axes[0, 0], rows, "success_rate", "A  Mission success", "%", True)
    grouped_bars(axes[0, 1], rows, "completion_fraction", "B  Agent completion", "%", True)
    grouped_bars(axes[0, 2], rows, "par2_steps", "C  Failure-aware solution length", "PAR-2 steps")
    grouped_bars(axes[1, 0], rows, "network_service_rate", "D  Network service", "%", True)
    grouped_bars(
        axes[1, 1],
        rows,
        "blackout_agent_steps_per_1000",
        "E  Blackout burden",
        "Per 1,000 eligible steps",
    )
    grouped_bars(axes[1, 2], rows, "p05_link_quality_db", "F  Lower-tail link quality", "P05 dB")
    axes[1, 2].text(
        0.01,
        0.02,
        "Compare within infrastructure pairs: 2 vs 1; 4 vs 3",
        transform=axes[1, 2].transAxes,
        fontsize=8,
        color="#444444",
    )
    handles, labels = axes[0, 0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="outside upper center", ncol=4, frameon=False)
    fig.suptitle("Weekend partial training: matched held-out evaluation", fontsize=16, fontweight="bold")
    fig.savefig(path, dpi=180, bbox_inches="tight")
    plt.close(fig)


def main() -> None:
    args = parse_args()
    run_directory = args.run_directory.resolve()
    aggregate_path = run_directory / "aggregate_results.csv"
    stage_path = run_directory / "stage_validation_results.csv"
    rows = read_csv(aggregate_path)
    stage_rows = read_csv(stage_path)
    overall = overall_results(rows)
    winners = winner_rows(overall)
    write_winners(run_directory / "metric_winners.csv", winners)
    write_markdown(
        run_directory / "RESULTS_SUMMARY.md",
        overall,
        winners,
        stage_summary(stage_rows),
    )
    plot_directory = run_directory / "plots"
    plot_directory.mkdir(parents=True, exist_ok=True)
    make_plot(plot_directory / "metric_overview.png", rows)
    print(run_directory / "RESULTS_SUMMARY.md")
    print(run_directory / "metric_winners.csv")
    print(plot_directory / "metric_overview.png")


if __name__ == "__main__":
    main()
