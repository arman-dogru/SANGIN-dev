from __future__ import annotations

from pathlib import Path
import unittest

from panama_uav.config import load_config
from panama_uav.evaluation import _episode_cap
from panama_uav.scenarios import Scenario


ROOT = Path(__file__).resolve().parents[1]


class PanamaReproductionConfigTests(unittest.TestCase):
    def test_curriculum_matches_intended_legacy_progression(self) -> None:
        config = load_config(ROOT / "configs/panama_reproduction.toml")

        self.assertIsNone(config.training.initial_model_path)
        self.assertEqual(config.training.target_environment_steps, 80_000_000)
        self.assertEqual(config.training.num_actors, 16)
        self.assertEqual(config.training.validation_epsilon, 0.0)
        self.assertFalse(config.training.force_graduate_on_max_episodes)
        self.assertEqual(
            [(stage.map_path, stage.num_agents, stage.max_episode_steps) for stage in config.curriculum],
            [
                ("maps/random-32-32-10.map", 2, 200),
                ("maps/random-32-32-10.map", 4, 200),
                ("maps/random-32-32-10.map", 6, 200),
                ("maps/random-32-32-20.map", 6, 200),
                ("maps/random-32-32-20.map", 8, 200),
                ("maps/random-64-64-10.map", 8, 400),
                ("maps/random-64-64-10.map", 12, 400),
                ("maps/random-64-64-20.map", 12, 400),
            ],
        )
        self.assertTrue(all(config.resolve(stage.map_path).exists() for stage in config.curriculum))
        self.assertEqual(config.curriculum[-1].graduation_success_rate, 1.0)

    def test_evaluation_covers_each_requested_map(self) -> None:
        config = load_config(ROOT / "configs/panama_reproduction.toml")

        self.assertEqual(config.evaluation.agent_counts, (4, 8, 16, 32, 64))
        self.assertEqual(config.evaluation.training_seeds, (42, 43, 44))
        self.assertEqual(
            config.evaluation.scenario_directories,
            (
                "scens/scen-random-32-32-10",
                "scens/scen-random-32-32-20",
                "scens/scen-random-64-64-10",
                "scens/scen-random-64-64-20",
            ),
        )

    def test_radio_fixture_is_explicit(self) -> None:
        config = load_config(ROOT / "configs/panama_reproduction.toml")

        self.assertEqual(config.map.meters_per_cell, 10.0)
        self.assertEqual(config.static_radio.site_layout, "hex7")
        self.assertEqual(config.static_radio.interference_margin_db, 9.0)
        self.assertEqual(config.static_radio.blackout_threshold_db, -8.47)
        self.assertEqual(config.uav.environment, "suburban")
        self.assertEqual(config.uav.max_path_loss_db, 90.0)

    def test_legacy_reward_coefficients_are_explicit(self) -> None:
        config = load_config(ROOT / "configs/panama_reproduction.toml")
        reward = config.reward

        self.assertEqual(reward.goal, 2.0)
        self.assertEqual(reward.time_step, -0.01)
        self.assertEqual(reward.collision_agent, -1.0)
        self.assertEqual(reward.collision_obstacle, -1.0)
        self.assertEqual(reward.distance_improvement, 0.23)
        self.assertEqual(reward.path_conflict, -1.0)
        self.assertEqual(reward.hold, 0.05)
        self.assertEqual(reward.active_yield, 0.0)
        self.assertEqual(reward.network_penalty, -0.4)
        self.assertEqual(reward.uav_movement_penalty, 0.0)

    def test_random64_evaluation_uses_curriculum_cap(self) -> None:
        config = load_config(ROOT / "configs/panama_reproduction.toml")
        scenario = Scenario(
            ROOT / "synthetic.scen",
            ROOT / "maps/random-64-64-10.map",
            ((0, 0),),
            ((0, 1),),
        )

        self.assertEqual(_episode_cap(config, scenario), 400)

        self.assertEqual(config.map.meters_per_cell, 10.0)
        self.assertEqual(config.static_radio.interference_margin_db, 9.0)
        self.assertEqual(config.uav.environment, "suburban")
        self.assertEqual(config.uav.max_path_loss_db, 90.0)
        self.assertEqual(config.uav.speed_m_per_step, 20.0)


if __name__ == "__main__":
    unittest.main()
