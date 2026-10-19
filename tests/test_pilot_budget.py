from dataclasses import replace
from pathlib import Path
import unittest
from unittest.mock import patch

from panama_uav.config import ExperimentMode, TrainingConfig, load_config
from panama_uav.training import train_policy, validate_random_policy
import tempfile
import json


ROOT = Path(__file__).resolve().parents[1]


class PilotBudgetTests(unittest.TestCase):
    def test_pilot_is_small_and_preserves_graduation(self):
        full = load_config(ROOT / "configs/panama_reproduction.toml")
        pilot = load_config(ROOT / "configs/panama_pilot.toml")
        self.assertLessEqual(pilot.training.target_environment_steps, full.training.target_environment_steps // 10)
        self.assertEqual(pilot.curriculum, full.curriculum)
        self.assertEqual(pilot.evaluation.training_seeds, (42,))
        self.assertFalse(pilot.training.force_graduate_on_max_episodes)

    def test_invalid_wall_budget(self):
        for value in (0, -1, float("inf"), float("nan")):
            with self.assertRaises(ValueError):
                TrainingConfig(max_wall_seconds=value)

    def test_exhausted_budget_saves_incomplete_status_without_starting_actors(self):
        config = load_config(ROOT / "configs/panama_pilot.toml")
        config = replace(config, training=replace(config.training, max_wall_seconds=1e-9))
        with tempfile.TemporaryDirectory() as directory:
            with patch("panama_uav.training.mp.get_context") as spawn:
                result = train_policy(config, ExperimentMode.MAPF, 42, directory, device_name="cpu")
                spawn.assert_not_called()
            self.assertFalse(result.curriculum_completed)
            self.assertEqual(result.environment_steps, 0)
            status = json.loads((Path(directory) / "training_status.json").read_text())
            self.assertIn("wall-time", status["blocked_reason"])
            self.assertTrue((Path(directory) / "checkpoint.pt").exists())
            with patch("panama_uav.training.mp.get_context") as spawn:
                train_policy(config, ExperimentMode.MAPF, 42, directory, device_name="cpu")
                spawn.assert_not_called()

    def test_validation_obeys_deadline(self):
        config = load_config(ROOT / "configs/panama_pilot.toml")
        with self.assertRaises(TimeoutError):
            validate_random_policy(config, ExperimentMode.MAPF, config.curriculum[0], None, 42, None, deadline=0)
