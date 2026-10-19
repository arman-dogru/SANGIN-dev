from __future__ import annotations

import csv
import json
from pathlib import Path
import tempfile
import unittest

import torch

from panama_uav.config import ExperimentMode, load_config
from panama_uav.evaluation import run_episode
from panama_uav.reporting import build_report
from panama_uav.scenarios import Scenario


ROOT = Path(__file__).resolve().parents[1]


class HoldModel(torch.nn.Module):
    def forward(self, observations: dict[str, torch.Tensor]) -> torch.Tensor:
        values = torch.zeros(
            (observations["spatial"].shape[0], 5),
            device=observations["spatial"].device,
        )
        values[:, 4] = 1.0
        return values


class ReportingTests(unittest.TestCase):
    def test_report_builds_complete_paired_tradeoff_outputs(self) -> None:
        config = load_config(ROOT / "configs/base.toml")
        map_path = (ROOT / "maps/test-10-10.map").resolve()
        scenario = Scenario(
            ROOT / "tests/reporting.scen",
            map_path,
            ((1, 1),),
            ((1, 1),),
        )
        with tempfile.TemporaryDirectory() as temporary:
            run_directory = Path(temporary)
            for mode in ExperimentMode:
                record, _ = run_episode(
                    config,
                    mode,
                    scenario,
                    HoldModel(),
                    training_seed=42,
                    episode_seed=99,
                    device=torch.device("cpu"),
                )
                record.update(
                    {
                        "policy_curriculum_completed": True,
                        "policy_final_stage_index": len(config.curriculum),
                        "policy_curriculum_stage_count": len(config.curriculum),
                        "policy_training_environment_steps": 100,
                        "policy_training_wall_seconds": 10.0,
                    }
                )
                evaluation = (
                    run_directory
                    / mode.value
                    / "seed-42"
                    / "evaluation"
                )
                evaluation.mkdir(parents=True)
                (evaluation / "episodes.jsonl").write_text(
                    json.dumps(record) + "\n",
                    encoding="utf-8",
                )

            report = build_report(run_directory, bootstrap_samples=0)
            self.assertTrue(report.is_file())
            self.assertTrue((run_directory / "plots" / "comparison.png").is_file())
            self.assertTrue((run_directory / "comparison_expectations.csv").is_file())
            with (run_directory / "paired_comparisons.csv").open(
                newline="",
                encoding="utf-8",
            ) as stream:
                rows = list(csv.DictReader(stream))
            self.assertTrue(
                any(
                    row["comparison"] == "uav_unaware_minus_static_unaware"
                    and float(row["action_trace_match_rate"]) == 1.0
                    for row in rows
                )
            )
            self.assertTrue(
                any(
                    row["comparison"] == "uav_aware_minus_static_unaware"
                    for row in rows
                )
            )


if __name__ == "__main__":
    unittest.main()
