#!/usr/bin/env python3
"""Summarize curriculum-stage validation performance for a completed run."""

from __future__ import annotations

import argparse
import csv
import json
import os
from pathlib import Path
from typing import Any

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


SETUP_LABELS = {
    "setup1_mapf": "MAPF only",
    "setup2_static_aware": "MAPF + network aware",
    "setup4_uav_aware": "MAPF + UAV aware",
}


def _records(path: Path) -> list[dict[str, Any]]:
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def _best_validation(records: list[dict[str, Any]]) -> dict[str, Any]:
    return max(
        records,
        key=lambda record: (
            float(record["success_rate"]),
            float(record["average_completion_fraction"]),
            -float(record["average_par2_steps"]),
            float(record["average_path_efficiency"]),
        ),
    )


def build_stage_results(run_directory: Path) -> tuple[Path, Path, Path]:
    rows: list[dict[str, Any]] = []
    for validation_path in sorted(
        run_directory.glob("setup*/seed-*/training/validation.jsonl")
    ):
        setup = validation_path.parents[2].name
        seed = int(validation_path.parents[1].name.removeprefix("seed-"))
        status_path = validation_path.parent / "training_status.json"
        status = json.loads(status_path.read_text(encoding="utf-8"))
        final_stage_index = int(status["final_stage_index"])
        grouped: dict[int, list[dict[str, Any]]] = {}
        for record in _records(validation_path):
            grouped.setdefault(int(record["stage_index"]), []).append(record)
        for stage_index, stage_records in sorted(grouped.items()):
            stage_records.sort(key=lambda record: int(record["environment_steps"]))
            first = stage_records[0]
            last = stage_records[-1]
            best = _best_validation(stage_records)
            rows.append(
                {
                    "setup": setup,
                    "setup_label": SETUP_LABELS.get(setup, setup),
                    "training_seed": seed,
                    "stage_index": stage_index,
                    "stage_name": best["stage_name"],
                    "graduated": stage_index < final_stage_index,
                    "validation_points": len(stage_records),
                    "last_stage_episode": int(last["stage_episode"]),
                    "first_environment_steps": int(first["environment_steps"]),
                    "last_environment_steps": int(last["environment_steps"]),
                    "first_success_rate": float(first["success_rate"]),
                    "last_success_rate": float(last["success_rate"]),
                    "best_success_rate": float(best["success_rate"]),
                    "best_completion_fraction": float(
                        best["average_completion_fraction"]
                    ),
                    "best_par2_steps": float(best["average_par2_steps"]),
                    "best_path_efficiency": float(
                        best["average_path_efficiency"]
                    ),
                    "best_successful_makespan_steps": float(
                        best["average_successful_steps"]
                    ),
                    "best_successful_makespan_stretch": best.get(
                        "average_successful_makespan_stretch"
                    ),
                    "best_p05_link_quality_db": float(
                        best["p05_link_quality_db"]
                    ),
                    "best_blackout_agent_steps_per_1000": float(
                        best["blackout_agent_steps_per_1000"]
                    ),
                    "best_network_service_rate": float(
                        best["network_service_rate"]
                    ),
                    "best_uav_distance_per_step_m": best.get(
                        "average_uav_distance_per_step_m"
                    ),
                    "best_uav_move_step_rate": best.get(
                        "average_uav_move_step_rate"
                    ),
                    "best_validation_environment_steps": int(
                        best["environment_steps"]
                    ),
                }
            )
    if not rows:
        raise FileNotFoundError(
            f"No training validation logs found under {run_directory}"
        )

    csv_path = run_directory / "stage_validation_results.csv"
    with csv_path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    markdown_path = run_directory / "STAGE_RESULTS.md"
    lines = [
        "# Curriculum-stage validation results",
        "",
        "Each row uses the validation checkpoint with the highest success rate in "
        "that stage; completion, PAR-2, path efficiency, link, blackout, and UAV "
        "values come from that same checkpoint.",
        "",
        "| Setup | Stage | Graduated | Validations | Best success | Completion | PAR-2 | Path efficiency | P05 link dB | Blackouts / 1k | Service | UAV m/step |",
        "|---|---:|:---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        uav = row["best_uav_distance_per_step_m"]
        lines.append(
            f"| {row['setup_label']} | {row['stage_index']} | "
            f"{'yes' if row['graduated'] else 'no'} | "
            f"{row['validation_points']} | {row['best_success_rate']:.1%} | "
            f"{row['best_completion_fraction']:.1%} | "
            f"{row['best_par2_steps']:.2f} | "
            f"{row['best_path_efficiency']:.3f} | "
            f"{row['best_p05_link_quality_db']:.2f} | "
            f"{row['best_blackout_agent_steps_per_1000']:.2f} | "
            f"{row['best_network_service_rate']:.1%} | "
            f"{'—' if uav is None else f'{float(uav):.2f}'} |"
        )
    markdown_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    plot_directory = run_directory / "plots"
    plot_directory.mkdir(exist_ok=True)
    os.environ.setdefault("MPLCONFIGDIR", str(run_directory / ".mplconfig"))
    panels = (
        ("best_success_rate", "Best validation success", "higher"),
        ("best_completion_fraction", "Completion fraction", "higher"),
        ("best_par2_steps", "PAR-2 steps", "lower"),
        ("best_path_efficiency", "Path efficiency", "higher"),
        ("best_p05_link_quality_db", "P05 link quality (dB)", "higher"),
        (
            "best_blackout_agent_steps_per_1000",
            "Blackouts / 1,000 active steps",
            "lower",
        ),
        ("best_network_service_rate", "Network service rate", "higher"),
        ("best_uav_distance_per_step_m", "UAV travel (m/step)", "lower"),
    )
    figure, axes = plt.subplots(2, 4, figsize=(18, 8), constrained_layout=True)
    for axis, (metric, title, direction) in zip(axes.flat, panels):
        for setup in SETUP_LABELS:
            selected = [
                row
                for row in rows
                if row["setup"] == setup and row.get(metric) is not None
            ]
            if not selected:
                continue
            selected.sort(key=lambda row: int(row["stage_index"]))
            axis.plot(
                [row["stage_index"] for row in selected],
                [float(row[metric]) for row in selected],
                marker="o",
                linewidth=1.7,
                label=SETUP_LABELS[setup],
            )
        axis.set_title(f"{title}\n({direction} is better)")
        axis.set_xlabel("Curriculum stage")
        axis.set_xticks(range(8))
        axis.grid(alpha=0.25)
    axes[0, 0].legend(fontsize=8)
    plot_path = plot_directory / "stage_performance.png"
    figure.savefig(plot_path, dpi=180)
    plt.close(figure)
    return csv_path, markdown_path, plot_path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_directory", type=Path)
    args = parser.parse_args()
    csv_path, markdown_path, plot_path = build_stage_results(
        args.run_directory.resolve()
    )
    print(f"CSV: {csv_path}")
    print(f"Summary: {markdown_path}")
    print(f"Plot: {plot_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
