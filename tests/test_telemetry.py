from __future__ import annotations

from pathlib import Path
import unittest

import numpy as np
import torch

from panama_uav.config import ExperimentMode, load_config
from panama_uav.evaluation import run_episode
from panama_uav.scenarios import Scenario


ROOT = Path(__file__).resolve().parents[1]


class HoldModel(torch.nn.Module):
    def forward(self, observations: dict[str, torch.Tensor]) -> torch.Tensor:
        batch = observations["spatial"].shape[0]
        values = torch.zeros((batch, 5), device=observations["spatial"].device)
        values[:, 4] = 1.0
        return values


class TelemetryTests(unittest.TestCase):
    def _scenario(self) -> Scenario:
        map_path = (ROOT / "maps/test-10-10.map").resolve()
        return Scenario(ROOT / "tests/synthetic.scen", map_path, ((1, 1),), ((1, 1),))

    def test_uav_episode_telemetry_has_aligned_agent_and_drone_arrays(self) -> None:
        config = load_config(ROOT / "configs/base.toml")
        record, telemetry = run_episode(
            config,
            ExperimentMode.UAV_AWARE,
            self._scenario(),
            HoldModel(),
            training_seed=42,
            episode_seed=99,
            device=torch.device("cpu"),
            collect_telemetry=True,
        )
        assert telemetry is not None
        self.assertTrue(record["success"])
        self.assertEqual(record["steps"], 1)
        self.assertEqual(record["agent_steps"], 1)
        self.assertEqual(record["task_active_agent_steps"], 0)
        self.assertEqual(record["service_eligible_agent_steps"], 0)
        self.assertEqual(record["uav_service_eligible_agent_steps"], 0)
        self.assertIn("makespan_lower_bound_steps", record)
        self.assertIn("sum_of_costs_lower_bound_steps", record)
        self.assertIn("makespan_stretch", record)
        self.assertIn("agent_move_fraction", record)
        self.assertIn("uav_distance_per_step_m", record)
        self.assertIn("uav_move_step_rate", record)
        self.assertEqual(record["link_quality_kind"], "effective_snr")
        self.assertEqual(len(record["action_trace_sha256"]), 64)
        self.assertIn("blackout_agent_steps_per_1000", record)
        self.assertEqual(int(telemetry["schema_version"]), 2)
        self.assertEqual(telemetry["agent_position_grid"].shape, (2, 1, 2))
        self.assertEqual(telemetry["selected_action"].shape, (1, 1))
        self.assertEqual(telemetry["communicated_path_grid"].shape, (2, 1, 6, 2))
        self.assertEqual(telemetry["agent_priority"].shape, (2, 1))
        self.assertEqual(telemetry["link_quality_db"].shape, (1, 1))
        self.assertEqual(telemetry["uav_position_m"].shape, (2, 3))
        self.assertEqual(telemetry["uav_target_position_m"].shape, (2, 3))
        np.testing.assert_array_equal(telemetry["service_eligible"], [[False]])
        np.testing.assert_array_equal(telemetry["blackout"], [[False]])
        np.testing.assert_array_equal(telemetry["uav_eligible_agents"], [0])
        np.testing.assert_array_equal(telemetry["time_s"], np.asarray([0.0, 1.0], dtype=np.float32))
        self.assertTrue(np.isfinite(telemetry["path_loss_db"]).all())
        self.assertTrue(np.isnan(telemetry["signal_dbm"]).all())
        self.assertEqual(str(telemetry["uav_environment"]), config.uav.environment)

    def test_static_episode_telemetry_contains_link_budget(self) -> None:
        config = load_config(ROOT / "configs/base.toml")
        _, telemetry = run_episode(
            config,
            ExperimentMode.STATIC_AWARE,
            self._scenario(),
            HoldModel(),
            training_seed=42,
            episode_seed=100,
            device=torch.device("cpu"),
            collect_telemetry=True,
        )
        assert telemetry is not None
        self.assertTrue(np.isfinite(telemetry["signal_dbm"]).all())
        self.assertTrue(np.isfinite(telemetry["interference_dbm"]).all())
        self.assertTrue(np.isfinite(telemetry["noise_dbm"]).all())
        self.assertEqual(telemetry["serving_node"].shape, (1, 1))
        self.assertEqual(str(telemetry["static_site_layout"]), config.static_radio.site_layout)
        self.assertEqual(
            float(telemetry["static_interference_margin_db"]),
            config.static_radio.interference_margin_db,
        )


if __name__ == "__main__":
    unittest.main()
