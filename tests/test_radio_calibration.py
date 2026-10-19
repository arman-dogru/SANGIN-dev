from __future__ import annotations

from dataclasses import replace
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import numpy as np

from panama_uav.config import load_config
from panama_uav.radio import StaticRadioField
from panama_uav.scenarios import load_map
from panama_uav.uav import AirToGroundModel
from scripts.calibrate_radio import build_report, static_map_metrics


ROOT = Path(__file__).resolve().parents[1]
REQUESTED_MAPS = (
    ROOT / "maps/random-32-32-10.map",
    ROOT / "maps/random-32-32-20.map",
    ROOT / "maps/random-64-64-10.map",
    ROOT / "maps/random-64-64-20.map",
)


class RadioCalibrationTests(unittest.TestCase):
    def test_interference_margin_creates_measurable_static_blackouts(self) -> None:
        config = load_config(ROOT / "configs/base.toml")
        grid = load_map(REQUESTED_MAPS[0])
        radio = replace(config.static_radio, site_layout="hex7", site_ring_radius_factor=0.65)
        uncalibrated = static_map_metrics(grid, REQUESTED_MAPS[0].name, 10.0, radio, 0.0)
        calibrated = static_map_metrics(grid, REQUESTED_MAPS[0].name, 10.0, radio, 9.0)
        actual = StaticRadioField(
            grid.shape,
            10.0,
            replace(radio, interference_margin_db=9.0),
            REQUESTED_MAPS[0].name,
        ).snapshot.quality_db[grid == 0]

        self.assertEqual(uncalibrated["blackout_fraction"], 0.0)
        self.assertGreaterEqual(calibrated["blackout_fraction"], 0.15)
        self.assertLessEqual(calibrated["blackout_fraction"], 0.40)
        self.assertLess(calibrated["p05_db"], config.static_radio.blackout_threshold_db)
        self.assertAlmostEqual(
            calibrated["blackout_fraction"],
            float(np.mean(actual < config.static_radio.blackout_threshold_db)),
        )

    def test_recommended_uav_geometry_is_partial_on_largest_maps(self) -> None:
        config = load_config(ROOT / "configs/base.toml")
        uav = replace(
            config.uav,
            environment="suburban",
            max_path_loss_db=90.0,
            speed_m_per_step=20.0,
        )
        model = AirToGroundModel(uav)

        self.assertTrue(np.isclose(model.maximum_radius_m, 275.7011533, atol=1e-5))
        self.assertTrue(np.isclose(model.optimal_height_m, 102.1967521, atol=1e-5))
        report = build_report(
            ROOT / "configs/base.toml",
            [str(path) for path in REQUESTED_MAPS],
            meters_per_cell=10.0,
            static_site_layout="hex7",
            site_ring_radius_factor=0.65,
            interference_margin_db=9.0,
            uav_environment="suburban",
            uav_max_path_loss_db=90.0,
            uav_speed_m_per_step=20.0,
            oracle_samples=2,
        )

        self.assertTrue(report["calibrated"])
        largest = [item for item in report["maps"] if item["shape_cells"] == [64, 64]]
        self.assertTrue(
            all(0.50 < item["uav_centered"]["served_fraction"] < 0.70 for item in largest)
        )

    def test_cli_writes_machine_readable_preflight_report(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "radio_calibration.json"
            command = [
                sys.executable,
                str(ROOT / "scripts/calibrate_radio.py"),
                "--config",
                str(ROOT / "configs/panama_reproduction.toml"),
                "--oracle-samples",
                "1",
                "--json-out",
                str(destination),
                "--require-calibrated",
            ]
            completed = subprocess.run(
                command,
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            payload = json.loads(destination.read_text())
        self.assertTrue(payload["calibrated"])
        self.assertEqual(len(payload["maps"]), 4)
        self.assertEqual(payload["parameters"]["static_site_layout"], "hex7")
        self.assertEqual(payload["parameters"]["interference_margin_db"], 9.0)


if __name__ == "__main__":
    unittest.main()
