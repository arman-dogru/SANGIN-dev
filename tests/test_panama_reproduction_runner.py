from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import unittest
from dataclasses import replace
from unittest.mock import patch

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
RUNNER_PATH = ROOT / "scripts" / "run_panama_reproduction.py"
SPEC = importlib.util.spec_from_file_location("run_panama_reproduction", RUNNER_PATH)
assert SPEC is not None and SPEC.loader is not None
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class PanamaReproductionRunnerTests(unittest.TestCase):
    def test_weekend_plans_three_time_bounded_policies_without_evaluation(self) -> None:
        config_path = ROOT / "configs/panama_weekend.toml"
        config = RUNNER.load_config(config_path)
        self.assertEqual(config.evaluation.training_seeds, (42,))
        self.assertEqual(config.training.max_wall_seconds * 3, 46.5 * 3600)
        self.assertFalse(config.training.force_graduate_on_max_episodes)
        self.assertEqual(config.curriculum, RUNNER.load_config(ROOT / "configs/panama_reproduction.toml").curriculum)
        with tempfile.TemporaryDirectory() as temporary:
            run_directory = Path(temporary) / "weekend"
            completed = subprocess.run([
                sys.executable, str(RUNNER_PATH), "--config", str(config_path),
                "--phase", "weekend", "--dry-run", "--run-directory", str(run_directory),
            ], cwd=ROOT, check=True, capture_output=True, text=True)
            self.assertFalse(run_directory.exists())
        commands = [line for line in completed.stdout.splitlines() if line.startswith("[command]")]
        training = [line for line in commands if " panama_uav train " in line]
        self.assertEqual(len(training), 3)
        for setup, command in zip((1, 2, 4), training):
            self.assertIn(f"--setup {setup}", command)
            self.assertIn("--seed 42", command)
        self.assertFalse(any(" panama_uav evaluate " in line or " panama_uav report " in line for line in commands))

    def test_comparison_config_is_bounded_and_evaluates_trained_agent_counts(self) -> None:
        config = RUNNER.load_config(ROOT / "configs/panama_comparison.toml")
        self.assertEqual(config.training.max_wall_seconds * 3, 46.5 * 3600)
        self.assertEqual(config.evaluation.training_seeds, (42,))
        self.assertEqual(config.evaluation.agent_counts, (4, 8, 12))
        self.assertFalse(config.evaluation.save_step_telemetry)
        self.assertGreaterEqual(config.training.epsilon_decay_steps, 3_000_000)
        self.assertEqual(config.reward.uav_movement_penalty, -0.02)

    def test_weekend_rejects_unbounded_and_over_budget_configs(self) -> None:
        with self.assertRaisesRegex(SystemExit, "requires a diagnostic config"):
            RUNNER.main(["--phase", "weekend", "--dry-run"])
        config = RUNNER.load_config(ROOT / "configs/panama_weekend.toml")
        config = replace(config, evaluation=replace(config.evaluation, training_seeds=(42, 43)))
        with patch.object(RUNNER, "load_config", return_value=config):
            with self.assertRaisesRegex(SystemExit, "at most 48 hours"):
                RUNNER.main(["--phase", "weekend", "--dry-run"])

    def test_pilot_cannot_launch_full_workflow(self) -> None:
        with self.assertRaisesRegex(SystemExit, "Diagnostic configs"):
            RUNNER.main([
                "--config", str(ROOT / "configs/panama_pilot.toml"),
                "--phase", "all", "--dry-run",
            ])

    def test_legacy_service_population_manifest_cannot_resume(self) -> None:
        config = RUNNER.load_config(ROOT / "configs/panama_reproduction.toml").profile("full")
        with tempfile.TemporaryDirectory() as temporary:
            run_directory = Path(temporary) / "legacy-run"
            run_directory.mkdir()
            (run_directory / "experiment_manifest.json").write_text(
                json.dumps(
                    {
                        "profile": "full",
                        "config": RUNNER._jsonable_config(config),
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(SystemExit, "older network-service definition"):
                RUNNER.validate_run_safety(
                    config,
                    run_directory,
                    resume=True,
                    phase="train-mapf",
                )

    def test_generated_scenario_has_reachable_unique_pairs(self) -> None:
        grid = np.zeros((8, 8), dtype=np.uint8)
        component = RUNNER._largest_component(grid)
        text = RUNNER._generated_scenario_text(
            Path("random-8-8-0.map"),
            grid,
            component,
            max_agents=8,
            rng=random.Random(2026),
        )

        lines = text.splitlines()
        self.assertEqual(lines[0], "version 1")
        self.assertEqual(len(lines), 9)
        endpoints: list[tuple[int, int]] = []
        for line in lines[1:]:
            fields = line.split()
            self.assertEqual(fields[1], "random-8-8-0.map")
            endpoints.extend(((int(fields[4]), int(fields[5])), (int(fields[6]), int(fields[7]))))
            self.assertGreater(float(fields[8]), 0.0)
        self.assertEqual(len(endpoints), len(set(endpoints)))

    def test_dry_run_trains_three_policies_and_evaluates_four_setups(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run_directory = Path(temporary) / "planned-run"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(RUNNER_PATH),
                    "--phase",
                    "all",
                    "--dry-run",
                    "--run-directory",
                    str(run_directory),
                ],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

        commands = [line for line in completed.stdout.splitlines() if line.startswith("[command]")]
        training = [line for line in commands if " panama_uav train " in line]
        evaluation = [line for line in commands if " panama_uav evaluate " in line]
        self.assertEqual(len(training), 9)
        self.assertEqual(len(evaluation), 12)
        self.assertFalse(any("--setup 3" in line for line in training))
        self.assertEqual(sum("--setup 3" in line for line in evaluation), 3)
        self.assertIn("setup 3 reuses the matching setup-1 seed", completed.stdout)

    def test_mapf_gate_only_plans_setup_one_training(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            completed = subprocess.run(
                [
                    sys.executable,
                    str(RUNNER_PATH),
                    "--phase",
                    "train-mapf",
                    "--training-seed",
                    "42",
                    "--dry-run",
                    "--run-directory",
                    str(Path(temporary) / "mapf-gate"),
                ],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

        training = [
            line
            for line in completed.stdout.splitlines()
            if line.startswith("[command]") and " panama_uav train " in line
        ]
        self.assertEqual(len(training), 1)
        self.assertTrue(all("--setup 1" in line for line in training))


if __name__ == "__main__":
    unittest.main()
