# Evaluation telemetry

When `evaluation.save_step_telemetry = true`, every evaluated episode writes one
compressed NumPy archive under:

`<evaluation-directory>/telemetry/<scenario>__n<agents>__seed<episode-seed>.npz`

The matching `episodes.jsonl` record contains `telemetry_path` and
`telemetry_schema_version`. Files contain only numeric and Unicode arrays and can
be opened safely with `numpy.load(path, allow_pickle=False)`.

## Array alignment

- State arrays such as `agent_position_grid`, `agent_at_goal`, `agent_priority`,
  and `communicated_path_grid` have `T + 1` rows and include the initial state.
- Action, radio, reward, event, and UAV step-diagnostic arrays have `T` rows and
  describe the transition ending at state row `t + 1`.
- Agent arrays use shape `[time, agent, ...]` and `agent_id` defines the agent
  axis.
- `time_s` uses the configured `map.seconds_per_step` conversion.

## Movement and task arrays

- `agent_position_grid`, `agent_position_xy_m`
- `agent_goal_grid`, `agent_goal_xy_m`
- `selected_action`, `executed_move_delta_grid`
- `agent_priority`, `agent_reward`, `communicated_path_grid`
- `agent_at_goal`, `agent_ever_reached_goal`, `first_arrival_step`
- `collision_agent`, `collision_obstacle`, `path_conflict`, `active_yield`

The XY arrays use cell centers in metres. Complete agent trajectories allow
pairwise distances and candidate direct agent-to-agent links to be reconstructed.
Communicated paths are padded with `-1`; combined with positions, priorities,
reached-goal state, and `communication_range_m`, they allow the simulator's
directed intention-message opportunities to be reconstructed.

## Network arrays

- `link_quality_db`, `link_quality_kind`, `normalized_link_quality`
- `service_eligible`, `blackout`, `physical_blackout`
- `radio_model`, `carrier_frequency_hz`, `bandwidth_hz`,
  `transmit_power_dbm`, `maximum_path_loss_db`
- `static_site_layout`, `static_interference_margin_db`, `uav_environment`
- `serving_node`, `serving_sector`
- `horizontal_distance_m`, `slant_distance_m`, `path_loss_db`
- `antenna_gain_db`, `signal_dbm`, `interference_dbm`, `noise_dbm`

For terrestrial service, link quality is SINR and the complete downlink budget is
available. For UAV service, link quality is the aerial model's effective SNR/link
margin. The aerial paper/configuration does not define transmit power, receiver
noise figure, bandwidth sharing, or interference, so `signal_dbm`,
`interference_dbm`, `noise_dbm`, and `antenna_gain_db` are deliberately `NaN`.
This prevents synthetic values from being mistaken for modeled physical outputs.

`service_eligible` is true only until an agent's first goal arrival. `blackout`
is the service metric and is therefore false for completed agents;
`physical_blackout` retains the raw threshold comparison for every physical
agent position. Raw link values are retained for all agents so alternative
packet models can still be reconstructed without treating completed users as
traffic demand.

## UAV arrays

- `uav_position_m`, `uav_target_position_m`
- `uav_distance_moved`, `uav_tracking_error_m`
- `uav_eligible_agents`, `uav_actual_served`, `uav_oracle_served`

These arrays are present only for setups 3 and 4. UAV target placement and all
three service counts use only unfinished agents. An agent is removed immediately
on the transition where it first reaches its goal.

The matching episode record also stores `agent_steps`,
`service_eligible_agent_steps`, `network_service_rate`, UAV actual/oracle service
rates, `blackout_agent_steps_per_1000`, and `blackout_entries_per_1000`. Blackout
rates are normalized by unfinished-agent service opportunities, not total agent
steps. These rates should be used alongside raw totals when comparing agent
counts or policies with different makespans.

Task-efficiency fields include `makespan_lower_bound_steps`,
`makespan_stretch`, `makespan_excess_steps`,
`sum_of_costs_lower_bound_steps`, `sum_of_costs_stretch`,
`sum_of_costs_excess_steps`, `par2_steps`, `path_efficiency`,
`agent_moves`, `task_active_agent_steps`, and `agent_move_fraction`. Lower
bounds are sums or maxima of
the independent obstacle-aware A* distances at reset. Stretch fields are reported
only for successful episodes; PAR-2 and censored sum-of-costs retain failures.
`agent_move_fraction` uses unfinished agents at the start of each action as its
denominator, including the action that reaches a goal.

UAV movement fields include `uav_distance_m`,
`uav_distance_per_step_m`, `uav_move_steps`, and
`uav_move_step_rate`. Normalized movement is the primary setup-3/setup-4
comparison because raw distance otherwise rewards policies simply for ending
episodes sooner. `action_trace_sha256` verifies that setup 3 used the exact
setup-1 action sequence on its paired scenario.

Every evaluation row also records whether its trained policy completed the
curriculum, its final stage index, training environment steps, and training wall
time. This prevents a time-bounded proof-of-concept policy from being confused
with a completed reproduction.

## Episode curves by curriculum stage

Use the scalar `training/training.jsonl` records to plot exploratory training
episodes, and `training/validation.jsonl` to plot policy test batches against the
training episode at which each batch ran. Episode numbering and smoothing reset
at each curriculum stage. Validation batch summaries do not contain the
individual validation episodes or raw blackout-onset counts; their normalized
onset rates are available.

The following commands add matched tests at every configured curriculum stage
and build PNG/PDF figures plus a local gallery:

```powershell
python scripts/evaluate_curriculum_curves.py 'artifacts/runs/<run-id>' --episodes-per-stage 25 --device cpu
python scripts/plot_curriculum_curves.py 'artifacts/runs/<run-id>'
python scripts/preview_curriculum_curves.py 'artifacts/runs/<run-id>' --port 8875
```

Open `http://127.0.0.1:8875/` while the preview command is running, or open
`plots/curriculum_episode_curves/index.html` under the run directory. The
gallery has training, validation, and test views for success, completion, mean
and P05 link quality, blackout event counts and normalized rates, outage duration,
service, UAV distance per episode and per step, moving-step rate, and PAR-2.
The stage panels use common y-axis scales and the setup labels `MAPF + STATIC
UNAWARE`, `MAPF + STATIC AWARE`, `MAPF + UAV UNAWARE`, and `MAPF + UAV AWARE`.

The supplementary tests evaluate each saved best policy on identical cases at
each stage's exact map, agent count, and episode cap. Policies remain frozen;
variation along the test-episode axis is case variation, not policy learning.
Checkpoint/scenario hashes and the configuration are recorded in
`curriculum_tests/manifest.json`; per-test records are stored separately from the
original final evaluation. Resume verifies that manifest before appending.

Setup 3 reuses setup 1's policy and therefore has no independent training log.
Its shared training task curves are dashed; historical UAV radio and motion
training measurements are unavailable. Missing stages and metrics are labeled.
Static setups show zero UAV travel because they contain no UAV. The gallery's
`episode_metrics.csv` and `data_coverage.csv` retain the measurements and their
availability explicitly.

## Packet-model use

Packet outcomes should be produced as a seeded post-processing experiment, leaving
the movement and radio telemetry unchanged. A paper should state the assumed
traffic direction, packet size/rate, bandwidth allocation, scheduler, SINR-to-BLER
curve, retransmission limit, and packet deadline. This separation permits several
packet models and sensitivity analyses to be compared using identical trajectories.
