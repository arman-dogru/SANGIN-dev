#!/usr/bin/env python3
"""Safely orchestrate the from-scratch PANAMA reproduction experiment.

The runner deliberately invokes each policy/setup separately so training,
evaluation, and reporting can be resumed as independent phases.  Setup 3 is
evaluated with setup 1's policy by the main CLI, which keeps the MAPF actions
paired while changing only the network infrastructure.
"""

from __future__ import annotations

import argparse
from collections import deque
import hashlib
import json
import os
from pathlib import Path
import random
import shlex
import subprocess
import sys
from typing import Iterable, Sequence


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = PROJECT_ROOT / "src"
DEFAULT_CONFIG = PROJECT_ROOT / "configs" / "panama_reproduction.toml"
POLICY_SETUPS = ("1", "2", "4")
EVALUATION_SETUPS = ("1", "2", "3", "4")
GENERATED_SCENARIOS_PER_MAP = 25
EXPERIMENT_SCHEMA_VERSION = 3
REWARD_SCHEMA_VERSION = 2
TRANSITION_POPULATION = "unfinished_agents"
SETUP_DIRECTORY_NAMES = {
    "1": "setup1_mapf",
    "2": "setup2_static_aware",
    "3": "setup3_uav_unaware",
    "4": "setup4_uav_aware",
}

if str(SOURCE_ROOT) not in sys.path:
    sys.path.insert(0, str(SOURCE_ROOT))

from panama_uav.config import ProjectConfig, load_config  # noqa: E402
from panama_uav.scenarios import load_map, load_scenario  # noqa: E402


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description=(
            "Train PANAMA from random initialization, evaluate all four static/UAV "
            "setups on matched seeds, and build the paper-ready report."
        )
    )
    result.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    destination = result.add_mutually_exclusive_group()
    destination.add_argument(
        "--run-id",
        default="panama-reproduction",
        help="stable name under artifacts/runs (reuse it to resume)",
    )
    destination.add_argument("--run-directory", type=Path, help="explicit artifact directory")
    result.add_argument(
        "--phase",
        choices=("preflight", "train-mapf", "train-network", "train", "weekend", "progress", "evaluate", "report", "all"),
        default="all",
        help="run a resumable phase; weekend trains three partial policies under a combined 48-hour training budget",
    )
    result.add_argument("--device", default="auto", help="auto, cpu, cuda, or mps")
    result.add_argument(
        "--training-seed",
        action="append",
        type=int,
        help="run only this configured seed in a training phase; repeat to select several",
    )
    result.add_argument(
        "--scenario-limit",
        type=positive_int,
        help="temporarily evaluate only the first N scenario files (omit for final results)",
    )
    result.add_argument(
        "--resume",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="resume checkpoints and completed evaluation episodes (default: true)",
    )
    result.add_argument(
        "--generate-missing-scenarios",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="deterministically create missing MovingAI evaluation corpora (default: true)",
    )
    result.add_argument(
        "--dry-run",
        action="store_true",
        help="validate and print the commands without creating artifacts or starting compute",
    )
    return result


def _run_root(config: ProjectConfig, args: argparse.Namespace) -> Path:
    if args.run_directory is not None:
        return args.run_directory.expanduser().resolve()
    if not args.run_id or Path(args.run_id).name != args.run_id or args.run_id in {".", ".."}:
        raise SystemExit("--run-id must be one simple directory name; use --run-directory for a path")
    return (config.resolve("artifacts/runs") / args.run_id).resolve()


def _jsonable_config(config: ProjectConfig) -> dict[str, object]:
    return json.loads(json.dumps(config.to_dict(), sort_keys=True))


def _nonempty_paths(directory: Path) -> list[Path]:
    if not directory.exists():
        return []
    return [path for path in directory.rglob("*") if path.is_file()]


def validate_run_safety(
    config: ProjectConfig,
    run_root: Path,
    *,
    resume: bool,
    phase: str,
) -> None:
    """Refuse ambiguous restarts that could mix or append incompatible data."""

    files = _nonempty_paths(run_root)
    manifest_path = run_root / "experiment_manifest.json"
    if files and not resume:
        raise SystemExit(
            f"Refusing --no-resume because {run_root} already contains artifacts. "
            "Choose a new --run-id to start from the beginning."
        )
    if not files:
        if phase in {"evaluate", "report"}:
            raise SystemExit(f"No existing run artifacts found under {run_root}")
        return

    # A calibration-only directory is possible if preflight completed before the
    # first training subprocess was started.  It is safe to continue from there.
    non_preflight = [
        path
        for path in files
        if path != run_root / "preflight" / "radio_calibration.json"
    ]
    if not manifest_path.exists():
        if non_preflight:
            raise SystemExit(
                f"Artifacts exist under {run_root}, but there is no experiment manifest. "
                "Use a new --run-id instead of risking a mixed run."
            )
        return

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if (
        manifest.get("experiment_schema_version") != EXPERIMENT_SCHEMA_VERSION
        or manifest.get("service_population") != "unfinished_agents"
        or manifest.get("reward_schema_version") != REWARD_SCHEMA_VERSION
        or manifest.get("transition_population") != TRANSITION_POPULATION
    ):
        raise SystemExit(
            f"Existing run {run_root} uses an older network-service definition. "
            "Choose a new --run-id and train from the beginning."
        )
    if manifest.get("profile") != "full":
        raise SystemExit(f"Existing run {run_root} was not created with the full profile")
    if manifest.get("config") != _jsonable_config(config):
        raise SystemExit(
            f"The resolved configuration differs from the manifest in {run_root}. "
            "Keep the old config to resume, or choose a new --run-id."
        )

    if phase in {"train-mapf", "train-network", "train", "weekend", "all"}:
        for seed in config.evaluation.training_seeds:
            for setup_name in (
                "setup1_mapf",
                "setup2_static_aware",
                "setup4_uav_aware",
            ):
                training = run_root / setup_name / f"seed-{seed}" / "training"
                contents = _nonempty_paths(training)
                if contents and not (training / "checkpoint.pt").exists():
                    raise SystemExit(
                        f"{training} contains partial output but no resumable checkpoint. "
                        "Use a new --run-id so logs are not silently appended to a restart."
                    )


def _component(grid, origin: tuple[int, int]) -> list[tuple[int, int]]:
    height, width = grid.shape
    seen = {origin}
    queue = deque([origin])
    while queue:
        row, column = queue.popleft()
        for delta_row, delta_column in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            neighbor = (row + delta_row, column + delta_column)
            if not (0 <= neighbor[0] < height and 0 <= neighbor[1] < width):
                continue
            if grid[neighbor] != 0 or neighbor in seen:
                continue
            seen.add(neighbor)
            queue.append(neighbor)
    return sorted(seen)


def _largest_component(grid) -> list[tuple[int, int]]:
    free = {(int(row), int(column)) for row, column in zip(*((grid == 0).nonzero()))}
    largest: list[tuple[int, int]] = []
    while free:
        component = _component(grid, min(free))
        free.difference_update(component)
        if len(component) > len(largest):
            largest = component
    return largest


def _distances(grid, start: tuple[int, int]) -> dict[tuple[int, int], int]:
    height, width = grid.shape
    result = {start: 0}
    queue = deque([start])
    while queue:
        row, column = queue.popleft()
        for delta_row, delta_column in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            neighbor = (row + delta_row, column + delta_column)
            if not (0 <= neighbor[0] < height and 0 <= neighbor[1] < width):
                continue
            if grid[neighbor] != 0 or neighbor in result:
                continue
            result[neighbor] = result[(row, column)] + 1
            queue.append(neighbor)
    return result


def _map_for_scenario_directory(config: ProjectConfig, directory: Path) -> Path:
    expected_stem = directory.name.removeprefix("scen-")
    candidates = {
        config.resolve(stage.map_path).resolve()
        for stage in config.curriculum
        if Path(stage.map_path).stem == expected_stem
    }
    if len(candidates) != 1:
        raise SystemExit(
            f"Cannot infer one curriculum map for scenario directory {directory}; "
            f"expected a map stem named {expected_stem!r}"
        )
    return candidates.pop()


def _generated_scenario_text(
    map_path: Path,
    grid,
    component: Sequence[tuple[int, int]],
    max_agents: int,
    rng: random.Random,
) -> str:
    height, width = grid.shape
    remaining = set(component)
    rows = ["version 1"]
    minimum_distance = max(4, (height + width) // 8)
    for agent in range(max_agents):
        if len(remaining) < 2:
            raise SystemExit(f"Not enough distinct traversable cells in {map_path} for {max_agents} agents")
        start = rng.choice(sorted(remaining))
        remaining.remove(start)
        distances = _distances(grid, start)
        eligible = [
            point
            for point in remaining
            if distances.get(point, -1) >= minimum_distance
        ]
        if not eligible:
            eligible = [point for point in remaining if point in distances]
        if not eligible:
            raise SystemExit(f"Could not construct reachable start/goal pairs for {map_path}")
        goal = rng.choice(sorted(eligible))
        remaining.remove(goal)
        start_row, start_column = start
        goal_row, goal_column = goal
        rows.append(
            "\t".join(
                (
                    str(agent),
                    map_path.name,
                    str(width),
                    str(height),
                    str(start_column),
                    str(start_row),
                    str(goal_column),
                    str(goal_row),
                    f"{float(distances[goal]):.8f}",
                )
            )
        )
    return "\n".join(rows) + "\n"


def prepare_missing_scenarios(
    config: ProjectConfig,
    *,
    generate: bool,
    dry_run: bool,
) -> None:
    max_agents = max(config.evaluation.agent_counts)
    for configured in config.evaluation.scenario_directories:
        directory = config.resolve(configured).resolve()
        scenario_files = sorted(directory.glob("*.scen")) if directory.exists() else []
        if len(scenario_files) < GENERATED_SCENARIOS_PER_MAP:
            if not generate:
                raise SystemExit(
                    f"Only {len(scenario_files)} scenario files found in {directory}; "
                    f"at least {GENERATED_SCENARIOS_PER_MAP} are required. Rerun without "
                    "--no-generate-missing-scenarios"
                )
            map_path = _map_for_scenario_directory(config, directory)
            if not map_path.exists():
                raise SystemExit(f"Evaluation map not found: {map_path}")
            missing_count = sum(
                not (directory / f"{map_path.stem}-generated-{index:02d}.scen").exists()
                for index in range(1, GENERATED_SCENARIOS_PER_MAP + 1)
            )
            print(
                f"[prepare] {'would generate' if dry_run else 'generating'} "
                f"{missing_count} missing scenarios in {directory}",
                flush=True,
            )
            if not dry_run:
                grid = load_map(map_path)
                component = _largest_component(grid)
                if len(component) < 2 * max_agents:
                    raise SystemExit(
                        f"Largest connected component in {map_path} has {len(component)} cells; "
                        f"at least {2 * max_agents} are required"
                    )
                directory.mkdir(parents=True, exist_ok=True)
                seed_bytes = hashlib.sha256(map_path.name.encode("utf-8")).digest()[:8]
                base_seed = int.from_bytes(seed_bytes, "big")
                for index in range(1, GENERATED_SCENARIOS_PER_MAP + 1):
                    destination = directory / f"{map_path.stem}-generated-{index:02d}.scen"
                    if destination.exists():
                        continue
                    rng = random.Random(base_seed + index)
                    text = _generated_scenario_text(map_path, grid, component, max_agents, rng)
                    temporary = destination.with_suffix(".scen.tmp")
                    temporary.write_text(text, encoding="utf-8")
                    temporary.replace(destination)
                scenario_files = sorted(directory.glob("*.scen"))
        if dry_run and not scenario_files:
            continue
        if len(scenario_files) < 1:
            raise SystemExit(f"No usable scenario files found in {directory}")
        for path in scenario_files:
            scenario = load_scenario(path, config.resolve("maps"))
            if len(scenario.starts) < max_agents:
                raise SystemExit(
                    f"{path} contains {len(scenario.starts)} agents, but evaluation requests {max_agents}"
                )
            selected = scenario.first(max_agents)
            if len(set(selected.starts)) != max_agents or len(set(selected.goals)) != max_agents:
                raise SystemExit(
                    f"{path} has duplicate starts or goals in its first {max_agents} rows"
                )
        print(f"[preflight] {directory}: {len(scenario_files)} scenarios, >= {max_agents} agents", flush=True)


def validate_config(config: ProjectConfig) -> None:
    if config.training.initial_model_path is not None:
        raise SystemExit(
            "panama_reproduction.toml must not set training.initial_model_path; "
            "this experiment is required to start from random initialization"
        )
    if not config.curriculum:
        raise SystemExit("The reproduction curriculum is empty")
    for stage in config.curriculum:
        map_path = config.resolve(stage.map_path)
        if not map_path.is_file():
            raise SystemExit(f"Curriculum map not found: {map_path}")
    seeds = config.evaluation.training_seeds
    if not seeds or len(set(seeds)) != len(seeds):
        raise SystemExit("evaluation.training_seeds must be a non-empty list of unique seeds")
    if not config.evaluation.agent_counts:
        raise SystemExit("evaluation.agent_counts must not be empty")
    if not config.evaluation.scenario_directories:
        raise SystemExit("evaluation.scenario_directories must not be empty")


def command_environment(run_root: Path) -> dict[str, str]:
    environment = dict(os.environ)
    existing = environment.get("PYTHONPATH")
    environment["PYTHONPATH"] = str(SOURCE_ROOT) + (os.pathsep + existing if existing else "")
    environment.setdefault("MPLCONFIGDIR", str(run_root / ".mplconfig"))
    return environment


def execute(command: Sequence[str], *, environment: dict[str, str], dry_run: bool) -> None:
    print(f"[command] {shlex.join(command)}", flush=True)
    if not dry_run:
        subprocess.run(command, cwd=PROJECT_ROOT, env=environment, check=True)


def shared_cli_args(config_path: Path, run_root: Path) -> list[str]:
    return [
        "--config",
        str(config_path),
        "--profile",
        "full",
        "--run-directory",
        str(run_root),
    ]


def run_calibration(
    config_path: Path,
    run_root: Path,
    *,
    environment: dict[str, str],
    dry_run: bool,
) -> None:
    calibration_script = PROJECT_ROOT / "scripts" / "calibrate_radio.py"
    if not calibration_script.is_file() and not dry_run:
        raise SystemExit(
            f"Radio calibration tool not found: {calibration_script}. "
            "The experiment must not run against an unvalidated radio field."
        )
    output = run_root / "preflight" / "radio_calibration.json"
    if not dry_run:
        output.parent.mkdir(parents=True, exist_ok=True)
    execute(
        [
            sys.executable,
            str(calibration_script),
            "--config",
            str(config_path),
            "--json-out",
            str(output),
            "--require-calibrated",
        ],
        environment=environment,
        dry_run=dry_run,
    )


def train(
    config: ProjectConfig,
    config_path: Path,
    run_root: Path,
    args: argparse.Namespace,
    environment: dict[str, str],
    setups: Sequence[str] = POLICY_SETUPS,
    seeds: Sequence[int] | None = None,
) -> None:
    resume_flag = "--resume" if args.resume else "--no-resume"
    for seed in seeds or config.evaluation.training_seeds:
        for setup in setups:
            execute(
                [
                    sys.executable,
                    "-m",
                    "panama_uav",
                    "train",
                    *shared_cli_args(config_path, run_root),
                    "--setup",
                    setup,
                    "--seed",
                    str(seed),
                    "--device",
                    args.device,
                    resume_flag,
                ],
                environment=environment,
                dry_run=args.dry_run,
            )


def _expected_model(run_root: Path, setup_name: str, seed: int) -> Path:
    training = run_root / setup_name / f"seed-{seed}" / "training"
    best = training / "best_model.pt"
    return best if best.exists() else training / "final_model.pt"


def validate_models(config: ProjectConfig, run_root: Path, *, dry_run: bool) -> None:
    if dry_run:
        return
    missing: list[Path] = []
    incomplete: list[tuple[Path, str]] = []
    for seed in config.evaluation.training_seeds:
        for setup_name in ("setup1_mapf", "setup2_static_aware", "setup4_uav_aware"):
            training = run_root / setup_name / f"seed-{seed}" / "training"
            model = _expected_model(run_root, setup_name, seed)
            if not model.is_file():
                missing.append(model)
                continue
            status_path = training / "training_status.json"
            if not status_path.is_file():
                incomplete.append((status_path, "training completion status is missing"))
                continue
            status = json.loads(status_path.read_text(encoding="utf-8"))
            if not status.get("curriculum_completed", False):
                incomplete.append(
                    (status_path, str(status.get("blocked_reason") or "curriculum did not complete"))
                )
    if missing:
        formatted = "\n".join(f"  - {path}" for path in missing)
        raise SystemExit(f"Evaluation requires trained models that are missing:\n{formatted}")
    if incomplete:
        formatted = "\n".join(f"  - {path}: {reason}" for path, reason in incomplete)
        if not config.evaluation.allow_partial_models:
            raise SystemExit(
                "Evaluation is blocked because training did not graduate every curriculum stage:\n"
                f"{formatted}"
            )
        print(
            "[evaluate] proof-of-concept mode: evaluating incomplete policies; "
            "training stage/step metadata will be attached to every episode\n"
            f"{formatted}",
            flush=True,
        )


def evaluate(
    config: ProjectConfig,
    config_path: Path,
    run_root: Path,
    args: argparse.Namespace,
    environment: dict[str, str],
) -> None:
    validate_models(config, run_root, dry_run=args.dry_run)
    resume_flag = "--resume" if args.resume else "--no-resume"
    for seed in config.evaluation.training_seeds:
        for setup in EVALUATION_SETUPS:
            command = [
                sys.executable,
                "-m",
                "panama_uav",
                "evaluate",
                *shared_cli_args(config_path, run_root),
                "--setup",
                setup,
                "--seed",
                str(seed),
                "--device",
                args.device,
                resume_flag,
            ]
            if args.scenario_limit is not None:
                command.extend(("--scenario-limit", str(args.scenario_limit)))
            execute(command, environment=environment, dry_run=args.dry_run)


def validate_paired_evaluations(
    config: ProjectConfig,
    run_root: Path,
    scenario_limit: int | None,
) -> None:
    scenario_paths = [
        path.resolve()
        for configured in config.evaluation.scenario_directories
        for path in sorted(config.resolve(configured).glob("*.scen"))
    ]
    if scenario_limit is not None:
        scenario_paths = scenario_paths[:scenario_limit]
    expected_keys = {
        (str(path), num_agents)
        for path in scenario_paths
        for num_agents in config.evaluation.agent_counts
    }
    if not expected_keys:
        raise SystemExit("No expected evaluation episodes were resolved")

    expected_episode_files: set[Path] = set()
    episode_seeds: dict[tuple[int, str, int], set[int]] = {}
    for training_seed in config.evaluation.training_seeds:
        for setup in EVALUATION_SETUPS:
            setup_name = SETUP_DIRECTORY_NAMES[setup]
            evaluation_directory = run_root / setup_name / f"seed-{training_seed}" / "evaluation"
            episode_path = evaluation_directory / "episodes.jsonl"
            expected_episode_files.add(episode_path.resolve())
            if not episode_path.is_file():
                raise SystemExit(f"Missing evaluation records: {episode_path}")
            records = [
                json.loads(line)
                for line in episode_path.read_text(encoding="utf-8").splitlines()
                if line.strip()
            ]
            actual_keys = {
                (str(Path(record["scenario_path"]).resolve()), int(record["num_agents"]))
                for record in records
            }
            if len(actual_keys) != len(records):
                raise SystemExit(f"Duplicate scenario/agent-count records found in {episode_path}")
            if actual_keys != expected_keys:
                missing = len(expected_keys - actual_keys)
                unexpected = len(actual_keys - expected_keys)
                raise SystemExit(
                    f"Incomplete or mismatched evaluation in {episode_path}: "
                    f"{missing} missing, {unexpected} unexpected episodes"
                )
            for record in records:
                if record.get("setup") != setup_name or int(record.get("training_seed", -1)) != training_seed:
                    raise SystemExit(f"Setup/seed metadata mismatch in {episode_path}")
                key = (
                    training_seed,
                    str(Path(record["scenario_path"]).resolve()),
                    int(record["num_agents"]),
                )
                episode_seeds.setdefault(key, set()).add(int(record["episode_seed"]))

            summary_path = evaluation_directory / "summary.json"
            if not summary_path.is_file():
                raise SystemExit(f"Missing evaluation summary: {summary_path}")
            if setup == "3":
                summary = json.loads(summary_path.read_text(encoding="utf-8"))
                expected_model = _expected_model(run_root, "setup1_mapf", training_seed).resolve()
                actual_model = Path(summary.get("model_path", "")).resolve()
                if actual_model != expected_model:
                    raise SystemExit(
                        f"Setup 3 seed {training_seed} did not reuse setup 1's model: "
                        f"expected {expected_model}, found {actual_model}"
                    )

    unexpected_files = {
        path.resolve() for path in run_root.glob("**/evaluation/episodes.jsonl")
    } - expected_episode_files
    if unexpected_files:
        formatted = "\n".join(f"  - {path}" for path in sorted(unexpected_files))
        raise SystemExit(f"Unexpected evaluation datasets would contaminate the report:\n{formatted}")
    unpaired = [key for key, seeds in episode_seeds.items() if len(seeds) != 1]
    if unpaired:
        raise SystemExit(f"Evaluation episode seeds are not paired across setups for {len(unpaired)} tasks")
    expected_total = len(expected_keys) * len(config.evaluation.training_seeds) * len(EVALUATION_SETUPS)
    print(f"[pre-report] verified {expected_total:,} complete, seed-paired episodes", flush=True)


def report(
    config: ProjectConfig,
    config_path: Path,
    run_root: Path,
    *,
    scenario_limit: int | None,
    environment: dict[str, str],
    dry_run: bool,
) -> None:
    if not dry_run:
        validate_paired_evaluations(config, run_root, scenario_limit)
    execute(
        [
            sys.executable,
            "-m",
            "panama_uav",
            "report",
            *shared_cli_args(config_path, run_root),
        ],
        environment=environment,
        dry_run=dry_run,
    )


def progress_report(
    config_path: Path,
    run_root: Path,
    *,
    environment: dict[str, str],
    dry_run: bool,
) -> None:
    execute(
        [
            sys.executable,
            "-m",
            "panama_uav",
            "progress",
            *shared_cli_args(config_path, run_root),
        ],
        environment=environment,
        dry_run=dry_run,
    )


def main(argv: Iterable[str] | None = None) -> int:
    args = parser().parse_args(argv)
    config_path = args.config.expanduser().resolve()
    if not config_path.is_file():
        raise SystemExit(f"Configuration not found: {config_path}")
    config = load_config(config_path).profile("full")
    validate_config(config)
    if config.training.diagnostic_run and args.phase not in {
        "preflight",
        "train-mapf",
        "weekend",
        "progress",
        "evaluate",
        "report",
    }:
        raise SystemExit(
            "Diagnostic configs do not support the all-in-one workflow; run their "
            "bounded training, progress, evaluation, and report phases explicitly"
        )
    if args.phase == "weekend":
        wall_limit = config.training.max_wall_seconds
        if not config.training.diagnostic_run or wall_limit is None:
            raise SystemExit("Weekend training requires a diagnostic config with max_wall_seconds, such as configs/panama_weekend.toml")
        total_seconds = wall_limit * len(config.evaluation.training_seeds) * len(POLICY_SETUPS)
        if total_seconds > 48 * 3600:
            raise SystemExit("Weekend policy budgets must total at most 48 hours across all seeds")
        print(f"[weekend] partial training: {total_seconds / 3600:g} hours maximum across three policies; preflight and final cleanup add overhead", flush=True)
        print("[weekend] retains actual curriculum progress; no automatic evaluation or full-reproduction claim", flush=True)
    if args.training_seed and args.phase not in {"train-mapf", "train-network", "train"}:
        raise SystemExit("--training-seed is available only with a dedicated training phase")
    training_seeds = tuple(args.training_seed or config.evaluation.training_seeds)
    unknown_seeds = sorted(set(training_seeds) - set(config.evaluation.training_seeds))
    if unknown_seeds:
        raise SystemExit(f"Training seeds are not present in the config: {unknown_seeds}")
    if len(set(training_seeds)) != len(training_seeds):
        raise SystemExit("--training-seed values must be unique")
    run_root = _run_root(config, args)
    validate_run_safety(config, run_root, resume=args.resume, phase=args.phase)
    environment = command_environment(run_root)

    print(f"[plan] config: {config_path}", flush=True)
    print(f"[plan] run directory: {run_root}", flush=True)
    print(
        f"[plan] configured seeds: {', '.join(map(str, config.evaluation.training_seeds))}",
        flush=True,
    )
    if training_seeds != tuple(config.evaluation.training_seeds):
        print(
            f"[plan] selected training seeds: {', '.join(map(str, training_seeds))}",
            flush=True,
        )
    print("[plan] trained policies: setup 1, setup 2, setup 4", flush=True)
    print("[plan] setup 3 reuses the matching setup-1 seed", flush=True)
    planned_setups = {
        "train-mapf": ("1",),
        "train-network": ("2", "4"),
    }.get(args.phase, POLICY_SETUPS)
    training_jobs = len(training_seeds) * len(planned_setups)
    maximum_training_steps = training_jobs * config.training.target_environment_steps
    minimum_evaluation_episodes = (
        len(config.evaluation.training_seeds)
        * len(EVALUATION_SETUPS)
        * len(config.evaluation.agent_counts)
        * len(config.evaluation.scenario_directories)
        * GENERATED_SCENARIOS_PER_MAP
    )
    print(
        f"[plan] {training_jobs} training jobs; up to {maximum_training_steps:,} "
        "joint environment steps before curriculum graduation",
        flush=True,
    )
    print(
        f"[plan] at least {minimum_evaluation_episodes:,} paired evaluation episodes",
        flush=True,
    )

    if args.phase not in {"report", "progress"}:
        prepare_missing_scenarios(
            config,
            generate=args.generate_missing_scenarios,
            dry_run=args.dry_run,
        )
        run_calibration(
            config_path,
            run_root,
            environment=environment,
            dry_run=args.dry_run,
        )
    if args.phase == "preflight":
        print("[done] preflight passed", flush=True)
        return 0
    if args.phase == "progress":
        progress_report(
            config_path,
            run_root,
            environment=environment,
            dry_run=args.dry_run,
        )
        print(f"[done] phase progress: {run_root}", flush=True)
        return 0
    if args.phase in {"train-mapf", "train-network", "train", "weekend", "all"}:
        train(
            config,
            config_path,
            run_root,
            args,
            environment,
            planned_setups,
            training_seeds,
        )
    if args.phase in {"evaluate", "all"}:
        evaluate(config, config_path, run_root, args, environment)
    if args.phase in {"report", "all"}:
        report(
            config,
            config_path,
            run_root,
            scenario_limit=args.scenario_limit,
            environment=environment,
            dry_run=args.dry_run,
        )
    print(f"[done] phase {args.phase}: {run_root}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
