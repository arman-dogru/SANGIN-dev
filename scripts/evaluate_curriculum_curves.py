"""Evaluate frozen saved policies on matched cases at every curriculum stage.

This adds a separate, resumable test dataset. It never trains or edits models.
"""
from __future__ import annotations

import argparse
from dataclasses import replace
import hashlib
import json
from pathlib import Path
import sys
import time

import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from panama_uav.config import ExperimentMode, load_config
from panama_uav.evaluation import run_episode
from panama_uav.models import DQN, choose_device
from panama_uav.scenarios import discover_scenarios
from panama_uav.training import REWARD_SCHEMA_VERSION, load_model_payload


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_directory", type=Path)
    parser.add_argument("--config", type=Path, default=Path("configs/panama_comparison.toml"))
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--episodes-per-stage", type=int, default=25)
    parser.add_argument("--device", default="cpu")
    args = parser.parse_args()
    if args.episodes_per_stage < 1:
        parser.error("--episodes-per-stage must be positive")
    config = load_config(args.config)
    root = args.run_directory.resolve()
    destination = root / "curriculum_tests"
    destination.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(1)
    device = choose_device(args.device)
    scenarios = discover_scenarios(
        [config.resolve(path) for path in config.evaluation.scenario_directories],
        config.resolve("maps"),
    )
    selected = {}
    for index, stage in enumerate(config.curriculum):
        cases = sorted(
            (case for case in scenarios if case.map_path == config.resolve(stage.map_path).resolve()),
            key=lambda case: case.path.name,
        )[:args.episodes_per_stage]
        if len(cases) != args.episodes_per_stage:
            raise ValueError(f"Stage {index} has {len(cases)} cases, requested {args.episodes_per_stage}")
        selected[index] = [case.first(stage.num_agents) for case in cases]
    models = {
        mode: root / mode.policy_mode.value / f"seed-{args.seed}" / "training" / "best_model.pt"
        for mode in ExperimentMode
    }
    manifest = {
        "schema_version": 1,
        "protocol": "fixed_best_policy_per_setup_all_curriculum_stages",
        "training_seed": args.seed,
        "episodes_per_stage": args.episodes_per_stage,
        "config": config.to_dict(),
        "models": {mode.value: {"path": str(path), "sha256": digest(path)} for mode, path in models.items()},
        "cases": {
            str(index): [{"path": str(case.path), "sha256": digest(case.path)} for case in cases]
            for index, cases in selected.items()
        },
    }
    # Normalize tuples from dataclass configuration before resume comparison.
    manifest = json.loads(json.dumps(manifest))
    manifest_path = destination / "manifest.json"
    if manifest_path.exists():
        if json.loads(manifest_path.read_text(encoding="utf-8")) != manifest:
            raise ValueError("Existing curriculum test manifest differs; use a separate output directory/run")
    else:
        manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    path = destination / "episodes.jsonl"
    records = []
    if path.exists():
        records = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    completed = {(record["setup"], record["stage_index"], record["test_episode"]) for record in records}
    if len(completed) != len(records):
        raise ValueError("Duplicate curriculum test records")
    start = time.monotonic()
    total = len(ExperimentMode) * len(config.curriculum) * args.episodes_per_stage
    for mode, model_path in models.items():
        payload = load_model_payload(model_path)
        if payload.get("mode") != mode.policy_mode.value or payload.get("reward_schema_version") != REWARD_SCHEMA_VERSION:
            raise ValueError(f"Unexpected policy mode/reward schema: {model_path}")
        fov = 2 * config.map.fov_radius + 1
        model = DQN((mode.policy_mode.spatial_channels, fov, fov), config.vector_length).to(device)
        model.load_state_dict(payload["model_state_dict"])
        model.eval()
        for index, stage in enumerate(config.curriculum):
            # Restrict the curriculum so run_episode uses this exact stage's cap.
            stage_config = replace(config, curriculum=(stage,))
            for episode, case in enumerate(selected[index], start=1):
                if (mode.value, index, episode) in completed:
                    continue
                episode_seed = args.seed * 1_000_000 + 30_000_000 + index * 10_000 + episode
                record, _ = run_episode(stage_config, mode, case, model, args.seed, episode_seed, device)
                record.update({
                    "stage_index": index,
                    "stage_name": stage.name,
                    "test_episode": episode,
                    "test_protocol": manifest["protocol"],
                    "model_sha256": manifest["models"][mode.value]["sha256"],
                })
                with path.open("a", encoding="utf-8") as stream:
                    stream.write(json.dumps(record, allow_nan=False, separators=(",", ":")) + "\n")
                records.append(record)
                completed.add((mode.value, index, episode))
            group = [record for record in records if record["setup"] == mode.value and record["stage_index"] == index]
            rate = sum(record["success"] for record in group) / len(group)
            print(f"[{len(records)}/{total}] {mode.value} stage {index}: {rate:.1%} success; elapsed {time.monotonic()-start:.0f}s", flush=True)
    shared = {(record["stage_index"], record["test_episode"]): record for record in records if record["setup"] == ExperimentMode.MAPF.value}
    for record in records:
        if record["setup"] == ExperimentMode.UAV_UNAWARE.value:
            reference = shared[(record["stage_index"], record["test_episode"])]
            for field in ("action_trace_sha256", "success", "steps", "completion_fraction", "par2_steps"):
                if record[field] != reference[field]:
                    raise ValueError(f"Shared-policy mismatch at stage {record['stage_index']}, test {record['test_episode']}: {field}")
    print(f"Verified {len(records)} records and exact static/UAV-unaware task traces. {path}", flush=True)


if __name__ == "__main__":
    main()
