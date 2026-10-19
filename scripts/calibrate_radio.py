#!/usr/bin/env python3
"""Measure and gate the radio calibration used by PANAMA/UAV experiments.

The PANAMA paper fixes the outage threshold and link-budget parameters, but it
does not publish enough site-layout detail to reconstruct its exact SINR map.
This utility therefore treats the radio field as an experimental fixture: it
reports map-wide distributions on traversable cells and fails preflight when
the terrestrial field has no useful outages or the UAV covers the largest map
trivially.

The optional interference margin represents aggregate co-channel interference
from network tiers omitted by the finite simulated deployment.  It is applied
to interference power (not subtracted blindly from SNR), and is intentionally
reported in every output artifact.
"""

from __future__ import annotations

import argparse
from dataclasses import fields, replace
import json
import math
from pathlib import Path
import sys
from typing import Any, Sequence

import numpy as np

from panama_uav.config import ProjectConfig, StaticRadioConfig, UAVConfig, load_config
from panama_uav.radio import RadioSnapshot, StaticRadioField
from panama_uav.scenarios import load_map
from panama_uav.uav import AirToGroundModel, UAVController


DEFAULT_MAPS = (
    "maps/random-32-32-10.map",
    "maps/random-32-32-20.map",
    "maps/random-64-64-10.map",
    "maps/random-64-64-20.map",
)
PERCENTILES = (0, 5, 25, 50, 75, 95, 100)


def _supports_field(instance: object, name: str) -> bool:
    return name in {item.name for item in fields(instance)}


def _raw_radio_config(config: StaticRadioConfig) -> StaticRadioConfig:
    """Disable a built-in margin so this utility can apply it exactly once."""

    if _supports_field(config, "interference_margin_db"):
        return replace(config, interference_margin_db=0.0)
    return config


def quality_with_interference_margin(
    snapshot: RadioSnapshot,
    interference_margin_db: float,
) -> np.ndarray:
    """Recompute SINR after scaling aggregate interference in linear power."""

    if not math.isfinite(interference_margin_db) or interference_margin_db < 0.0:
        raise ValueError("interference_margin_db must be finite and non-negative")
    signal_mw = np.power(10.0, snapshot.signal_dbm.astype(np.float64) / 10.0)
    interference_mw = np.power(10.0, snapshot.interference_dbm.astype(np.float64) / 10.0)
    noise_mw = np.power(10.0, snapshot.noise_dbm.astype(np.float64) / 10.0)
    scaled_interference = interference_mw * (10.0 ** (interference_margin_db / 10.0))
    return 10.0 * np.log10(signal_mw / np.maximum(scaled_interference + noise_mw, 1e-30))


def _distribution(values: np.ndarray, threshold_db: float) -> dict[str, Any]:
    percentiles = np.percentile(values, PERCENTILES)
    return {
        "samples": int(values.size),
        "minimum_db": float(percentiles[0]),
        "p05_db": float(percentiles[1]),
        "p25_db": float(percentiles[2]),
        "median_db": float(percentiles[3]),
        "p75_db": float(percentiles[4]),
        "p95_db": float(percentiles[5]),
        "maximum_db": float(percentiles[6]),
        "mean_db": float(values.mean()),
        "blackout_fraction": float(np.mean(values < threshold_db)),
        "served_fraction": float(np.mean(values >= threshold_db)),
    }


def static_map_metrics(
    grid: np.ndarray,
    map_key: str,
    meters_per_cell: float,
    config: StaticRadioConfig,
    interference_margin_db: float,
) -> dict[str, Any]:
    snapshot = StaticRadioField(
        grid.shape,
        meters_per_cell,
        _raw_radio_config(config),
        map_key,
    ).snapshot
    quality_db = quality_with_interference_margin(snapshot, interference_margin_db)
    return _distribution(quality_db[grid == 0], config.blackout_threshold_db)


def _oracle_served_fraction(
    grid: np.ndarray,
    meters_per_cell: float,
    config: UAVConfig,
    agent_count: int,
    sample_count: int,
    seed: int,
) -> float | None:
    if sample_count <= 0:
        return None
    cells = np.argwhere(grid == 0)
    count = min(agent_count, len(cells))
    controller = UAVController(grid.shape, meters_per_cell, config)
    rng = np.random.default_rng(seed)
    fractions: list[float] = []
    for _ in range(sample_count):
        chosen = cells[rng.choice(len(cells), size=count, replace=False)]
        points_xy_m = np.asarray(
            [[(col + 0.5) * meters_per_cell, (row + 0.5) * meters_per_cell] for row, col in chosen],
            dtype=np.float64,
        )
        _, covered = controller.optimal_target(points_xy_m)
        fractions.append(float(covered.mean()))
    return float(np.mean(fractions))


def uav_map_metrics(
    grid: np.ndarray,
    meters_per_cell: float,
    config: UAVConfig,
    oracle_agent_count: int,
    oracle_samples: int,
    seed: int,
) -> dict[str, Any]:
    controller = UAVController(grid.shape, meters_per_cell, config)
    quality_db = controller.snapshot().quality_db[grid == 0].astype(np.float64)
    result = _distribution(quality_db, config.blackout_threshold_db)
    result["oracle_served_fraction"] = _oracle_served_fraction(
        grid,
        meters_per_cell,
        config,
        oracle_agent_count,
        oracle_samples,
        seed,
    )
    return result


def _resolved_maps(project: ProjectConfig, values: Sequence[str]) -> list[Path]:
    paths = [project.resolve(value).resolve() for value in values]
    missing = [str(path) for path in paths if not path.is_file()]
    if missing:
        raise FileNotFoundError(f"Map files not found: {', '.join(missing)}")
    return paths


def build_report(
    config_path: str | Path,
    map_values: Sequence[str] = DEFAULT_MAPS,
    *,
    meters_per_cell: float | None = None,
    static_site_layout: str | None = None,
    site_ring_radius_factor: float | None = None,
    interference_margin_db: float | None = None,
    uav_environment: str | None = None,
    uav_max_path_loss_db: float | None = None,
    uav_speed_m_per_step: float | None = None,
    static_blackout_min: float = 0.15,
    static_blackout_max: float = 0.40,
    largest_map_uav_coverage_min: float = 0.20,
    largest_map_uav_coverage_max: float = 0.80,
    expected_threshold_db: float = -8.47,
    oracle_agent_count: int = 16,
    oracle_samples: int = 32,
    sampling_seed: int = 2025,
) -> dict[str, Any]:
    project = load_config(config_path)
    scale = float(project.map.meters_per_cell if meters_per_cell is None else meters_per_cell)
    if not math.isfinite(scale) or scale <= 0.0:
        raise ValueError("meters_per_cell must be finite and positive")

    static_overrides: dict[str, Any] = {}
    if static_site_layout is not None:
        static_overrides["site_layout"] = static_site_layout
    if site_ring_radius_factor is not None:
        static_overrides["site_ring_radius_factor"] = float(site_ring_radius_factor)
    static_config = replace(project.static_radio, **static_overrides)
    configured_margin = float(getattr(static_config, "interference_margin_db", 0.0))
    margin = configured_margin if interference_margin_db is None else float(interference_margin_db)
    uav_overrides: dict[str, Any] = {}
    if uav_environment is not None:
        uav_overrides["environment"] = uav_environment
    if uav_max_path_loss_db is not None:
        uav_overrides["max_path_loss_db"] = float(uav_max_path_loss_db)
    if uav_speed_m_per_step is not None:
        uav_overrides["speed_m_per_step"] = float(uav_speed_m_per_step)
    uav_config = replace(project.uav, **uav_overrides)
    map_paths = _resolved_maps(project, map_values)

    map_reports: list[dict[str, Any]] = []
    for index, path in enumerate(map_paths):
        grid = load_map(path)
        height, width = grid.shape
        map_reports.append(
            {
                "map": str(path),
                "shape_cells": [int(height), int(width)],
                "physical_size_m": [float(height * scale), float(width * scale)],
                "traversable_cells": int(np.count_nonzero(grid == 0)),
                "static": static_map_metrics(
                    grid,
                    path.name,
                    scale,
                    static_config,
                    margin,
                ),
                "uav_centered": uav_map_metrics(
                    grid,
                    scale,
                    uav_config,
                    oracle_agent_count,
                    oracle_samples,
                    sampling_seed + index,
                ),
            }
        )

    maximum_cells = max(item["shape_cells"][0] * item["shape_cells"][1] for item in map_reports)
    largest = [
        item for item in map_reports if item["shape_cells"][0] * item["shape_cells"][1] == maximum_cells
    ]
    threshold_ok = (
        math.isclose(static_config.blackout_threshold_db, expected_threshold_db, abs_tol=1e-9)
        and math.isclose(uav_config.blackout_threshold_db, expected_threshold_db, abs_tol=1e-9)
    )
    static_ok = all(
        static_blackout_min <= item["static"]["blackout_fraction"] <= static_blackout_max
        for item in map_reports
    )
    uav_partial_ok = all(
        largest_map_uav_coverage_min
        <= item["uav_centered"]["served_fraction"]
        <= largest_map_uav_coverage_max
        for item in largest
    )
    model = AirToGroundModel(uav_config)
    checks = {
        "paper_threshold_preserved": threshold_ok,
        "static_blackouts_in_range_on_every_map": static_ok,
        "uav_coverage_partial_on_every_largest_map": uav_partial_ok,
    }
    site_layout = getattr(static_config, "site_layout", "edge_pair")
    sector_count = {
        "edge_pair": 6,
        "hex7": 21,
    }.get(site_layout)
    theoretical_floor = None
    if sector_count is not None and sector_count > 1:
        theoretical_floor = -10.0 * math.log10(sector_count - 1)
    return {
        "schema_version": 1,
        "config": str(Path(config_path).resolve()),
        "calibrated": all(checks.values()),
        "checks": checks,
        "criteria": {
            "expected_blackout_threshold_db": expected_threshold_db,
            "static_blackout_fraction": [static_blackout_min, static_blackout_max],
            "largest_map_uav_centered_served_fraction": [
                largest_map_uav_coverage_min,
                largest_map_uav_coverage_max,
            ],
        },
        "parameters": {
            "meters_per_cell": scale,
            "static_site_layout": site_layout,
            "static_sector_count": sector_count,
            "interference_limited_sinr_floor_db": theoretical_floor,
            "interference_margin_db": margin,
            "static_blackout_threshold_db": static_config.blackout_threshold_db,
            "uav_environment": uav_config.environment,
            "uav_max_path_loss_db": uav_config.max_path_loss_db,
            "uav_speed_m_per_step": uav_config.speed_m_per_step,
            "uav_blackout_threshold_db": uav_config.blackout_threshold_db,
            "uav_maximum_radius_m": model.maximum_radius_m,
            "uav_optimal_height_m": model.optimal_height_m,
        },
        "maps": map_reports,
    }


def _print_report(report: dict[str, Any]) -> None:
    status = "PASS" if report["calibrated"] else "FAIL"
    parameters = report["parameters"]
    print(f"Radio calibration: {status}")
    print(
        "Parameters: "
        f"{parameters['meters_per_cell']:.3g} m/cell, "
        f"layout={parameters['static_site_layout']}, "
        f"interference margin={parameters['interference_margin_db']:.2f} dB, "
        f"UAV radius={parameters['uav_maximum_radius_m']:.1f} m, "
        f"UAV height={parameters['uav_optimal_height_m']:.1f} m"
    )
    print("Map                         Static blackout   Static p05   UAV center served   UAV oracle served")
    for item in report["maps"]:
        static = item["static"]
        uav = item["uav_centered"]
        oracle = uav["oracle_served_fraction"]
        oracle_text = "n/a" if oracle is None else f"{oracle:.1%}"
        print(
            f"{Path(item['map']).name:28s}"
            f"{static['blackout_fraction']:9.1%}  "
            f"{static['p05_db']:11.2f} dB  "
            f"{uav['served_fraction']:16.1%}  "
            f"{oracle_text:18s}"
        )
    for name, passed in report["checks"].items():
        print(f"  {'PASS' if passed else 'FAIL'}  {name}")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="configs/base.toml")
    parser.add_argument("--map", action="append", dest="maps", help="Map path; repeat for multiple maps")
    parser.add_argument("--meters-per-cell", type=float)
    parser.add_argument("--static-site-layout")
    parser.add_argument("--site-ring-radius-factor", type=float)
    parser.add_argument("--interference-margin-db", type=float)
    parser.add_argument("--uav-environment")
    parser.add_argument("--uav-max-path-loss-db", type=float)
    parser.add_argument("--uav-speed-m-per-step", type=float)
    parser.add_argument("--static-blackout-min", type=float, default=0.15)
    parser.add_argument("--static-blackout-max", type=float, default=0.40)
    parser.add_argument("--largest-map-uav-coverage-min", type=float, default=0.20)
    parser.add_argument("--largest-map-uav-coverage-max", type=float, default=0.80)
    parser.add_argument("--expected-threshold-db", type=float, default=-8.47)
    parser.add_argument("--oracle-agent-count", type=int, default=16)
    parser.add_argument("--oracle-samples", type=int, default=32)
    parser.add_argument("--sampling-seed", type=int, default=2025)
    parser.add_argument("--json-out", type=Path)
    parser.add_argument(
        "--require-calibrated",
        action="store_true",
        help="Exit with status 2 if any calibration gate fails",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        report = build_report(
            args.config,
            args.maps or DEFAULT_MAPS,
            meters_per_cell=args.meters_per_cell,
            static_site_layout=args.static_site_layout,
            site_ring_radius_factor=args.site_ring_radius_factor,
            interference_margin_db=args.interference_margin_db,
            uav_environment=args.uav_environment,
            uav_max_path_loss_db=args.uav_max_path_loss_db,
            uav_speed_m_per_step=args.uav_speed_m_per_step,
            static_blackout_min=args.static_blackout_min,
            static_blackout_max=args.static_blackout_max,
            largest_map_uav_coverage_min=args.largest_map_uav_coverage_min,
            largest_map_uav_coverage_max=args.largest_map_uav_coverage_max,
            expected_threshold_db=args.expected_threshold_db,
            oracle_agent_count=args.oracle_agent_count,
            oracle_samples=args.oracle_samples,
            sampling_seed=args.sampling_seed,
        )
    except (FileNotFoundError, ValueError) as exc:
        print(f"Radio calibration error: {exc}", file=sys.stderr)
        return 2
    _print_report(report)
    if args.json_out is not None:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(f"Wrote {args.json_out}")
    return 2 if args.require_calibrated and not report["calibrated"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
