classdef ExperimentEnvironment < handle
    %EXPERIMENTENVIRONMENT Retained PANAMA 0.1 task dynamics with received mission
    %   information (src/panama_uav/environment.py:ExperimentEnvironment).
    %
    %   env = panama_uav.environment.ExperimentEnvironment(config, map_path, ...
    %             num_agents, max_episode_steps, seed, scenario)
    %   [obs, info] = env.reset('seed', s, 'starts', S, 'goals', G, 'windows', W)
    %   result = env.step(actions)      % actions(k) for agent id k-1, 0..4
    %
    %   Positions are zero-based [row col] as in Python. Observations are a
    %   1-by-N struct array with fields spatial (single fov-by-fov-by-3,
    %   channels obstacles/robots/intentions; Python's layout is 3-by-fov-by-fov)
    %   and vector (single 1-by-12). Starts/goals and reservation windows
    %   drawn by NumPy can be injected through reset() for exact parity.
    properties
        config
        map_path
        grid
        height
        width
        num_agents
        max_episode_steps
        base_seed
        rng            % panama_uav.util.Xorshift128; replaces np.random.default_rng(seed)
        scenario
        fov_radius
        fov_size
        communication_range
        padded_grid
        agents
        communicated_paths = {}
        step_count = 0
        radio_snapshot
        uav
        communication
    end
    properties (Constant)
        ACTION_DELTAS = [-1 0; 1 0; 0 -1; 0 1; 0 0]
    end
    methods
        function obj = ExperimentEnvironment(config, map_path, num_agents, max_episode_steps, seed, scenario)
            if nargin < 6
                scenario = [];
            end
            obj.config = config;
            obj.map_path = panama_uav.config.resolve(config, map_path);
            obj.grid = panama_uav.scenarios.load_map(obj.map_path);
            [obj.height, obj.width] = size(obj.grid);
            obj.num_agents = num_agents;
            obj.max_episode_steps = max_episode_steps;
            obj.base_seed = seed;
            obj.rng = panama_uav.util.Xorshift128(seed);
            if ~isempty(scenario)
                scenario = panama_uav.scenarios.first(scenario, num_agents);
            end
            obj.scenario = scenario;
            obj.fov_radius = config.map.fov_radius;
            obj.fov_size = 2 * obj.fov_radius + 1;
            obj.communication_range = fix(obj.fov_radius * config.map.communication_range_factor);
            r = obj.fov_radius;
            obj.padded_grid = ones(obj.height + 2 * r, obj.width + 2 * r, 'uint8');
            obj.padded_grid(r + 1:r + obj.height, r + 1:r + obj.width) = obj.grid;
            if max_episode_steps > 250
                error('panama_uav:environment', 'Study episodes cannot exceed 250 steps');
            end
            obj.uav = panama_uav.uav.UAVController([obj.height obj.width], ...
                config.map.meters_per_cell, config.uav);
        end

        function [spatial, vector_length] = observation_shape(obj)
            %OBSERVATION_SHAPE Python returns ((3, fov, fov), vector_length); the
            %   MATLAB spatial layout is [fov fov 3].
            spatial = [obj.fov_size, obj.fov_size, 3];
            vector_length = panama_uav.config.vector_length(obj.config);
        end

        function observations = prepare_decision(obj, deadline_seconds) %#ok<STOUT,INUSD>
            %PREPARE_DECISION Decision-deadline processing (environment.py:prepare_decision).
            error('panama_uav:notImplemented', ['ExperimentEnvironment.prepare_decision is not ported yet ', ...
                '(Python: environment.py:prepare_decision -> information.py:prepare_decision; milestone M4)']);
        end

        function tf = all_agents_at_goals(obj)
            tf = ~isempty(obj.agents) && all(arrayfun(@(a) isequal(a.position, a.goal), obj.agents));
        end

        function [observations, info] = reset(obj, varargin)
            opts = panama_uav.util.parse_options(struct('seed', [], 'starts', [], 'goals', [], ...
                'windows', []), varargin, 'ExperimentEnvironment.reset');
            if isempty(opts.starts) ~= isempty(opts.goals)
                error('panama_uav:options', 'reset: inject starts and goals together');
            end
            % Python: reset(seed) replaces self.rng; reset() keeps advancing it.
            if ~isempty(opts.seed)
                obj.rng = panama_uav.util.Xorshift128(opts.seed);
            end
            obj.step_count = 0;
            if ~isempty(opts.starts)
                starts = double(opts.starts);
                goals = double(opts.goals);
            elseif isempty(obj.scenario)
                [starts, goals] = obj.random_starts_and_goals();
            else
                starts = obj.scenario.starts;
                goals = obj.scenario.goals;
            end
            if size(unique(starts, 'rows'), 1) ~= size(starts, 1)
                error('panama_uav:environment', 'Scenario contains duplicate start locations');
            end
            template = struct('id', 0, 'position', [0 0], 'goal', [0 0], 'priority', inf, ...
                'path', zeros(0, 2), 'distance_to_goal', inf, 'previous_distance_to_goal', inf, ...
                'initial_distance_to_goal', inf, 'ever_reached_goal', false);
            obj.agents = repmat(template, 1, obj.num_agents);
            obj.communicated_paths = cell(1, obj.num_agents);
            for k = 1:obj.num_agents
                obj.agents(k).id = k - 1;
                obj.agents(k).position = starts(k, :);
                obj.agents(k).goal = goals(k, :);
                obj.refresh_path(k);
                obj.agents(k).previous_distance_to_goal = obj.agents(k).distance_to_goal;
                obj.agents(k).initial_distance_to_goal = obj.agents(k).distance_to_goal;
                if isequal(obj.agents(k).position, obj.agents(k).goal)
                    obj.agents(k).ever_reached_goal = true;
                end
            end
            obj.refresh_priorities();
            obj.uav.reset();
            obj.radio_snapshot = obj.uav.snapshot();
            seed = obj.base_seed;
            if ~isempty(opts.seed)
                seed = opts.seed;
            end
            obj.communication = panama_uav.information.MissionCommunication(obj.config.communication, ...
                obj.grid, obj.agents, @panama_uav.environment.astar_path, seed, ...
                obj.max_episode_steps, opts.windows);
            d = [obj.agents.initial_distance_to_goal];
            d = d(isfinite(d));
            if isempty(d)
                info.max_initial_astar_distance = 0.0;
            else
                info.max_initial_astar_distance = max(d);
            end
            observations = obj.observations();
        end

        function o = observation(obj, k)
            agent = obj.agents(k);
            [path, received_distance, intentions, priorities] = ...
                obj.communication.observation_values(agent);
            row = agent.position(1);
            col = agent.position(2);
            n = obj.fov_size;
            r = obj.fov_radius;
            obstacles = single(obj.padded_grid(row + 1:row + n, col + 1:col + n));
            others = zeros(n, n, 'single');
            marks = zeros(n, n, 'single');
            for j = 1:numel(obj.agents)
                if j == k
                    continue;
                end
                other = obj.agents(j);
                dr = other.position(1) - row;
                dc = other.position(2) - col;
                if abs(dr) <= r && abs(dc) <= r
                    others(dr + r + 1, dc + r + 1) = 1;
                end
                if ~intentions{j}.completed && priorities(j) < priorities(k) ...
                        && panama_uav.environment.manhattan(agent.position, other.position) ...
                        <= obj.communication_range
                    p = intentions{j}.path;
                    for q = 1:size(p, 1)
                        rr = p(q, 1) - row;
                        rc = p(q, 2) - col;
                        if abs(rr) <= r && abs(rc) <= r
                            marks(rr + r + 1, rc + r + 1) = 1;
                        end
                    end
                end
            end
            normalizer = agent.initial_distance_to_goal;
            if ~(normalizer > 0 && isfinite(normalizer))
                normalizer = max(obj.width, obj.height);
            end
            if isfinite(received_distance)
                nd = min(max(received_distance / normalizer, 0.0), 1.0);
            else
                nd = 1.0;
            end
            waypoints = obj.config.map.astar_waypoints;
            vector = zeros(1, 2 + 2 * waypoints);
            vector(1) = nd;
            vector(2) = double(agent.ever_reached_goal);
            wn = max(obj.fov_radius, 1);
            for offset = 1:waypoints
                if offset < size(path, 1)
                    w = path(offset + 1, :);
                    vector(1 + 2 * offset) = min(max((w(1) - row) / wn, -1.0), 1.0);
                    vector(2 + 2 * offset) = min(max((w(2) - col) / wn, -1.0), 1.0);
                end
            end
            o = struct('spatial', cat(3, obstacles, others, marks), 'vector', single(vector));
        end

        function obs = observations(obj)
            obs = struct('spatial', {}, 'vector', {});
            for k = 1:numel(obj.agents)
                obs(k) = obj.observation(k);
            end
        end

        function result = step(obj, actions)
            if isempty(obj.agents)
                error('panama_uav:environment', 'reset() must be called before step()');
            end
            if obj.step_count >= obj.max_episode_steps
                error('panama_uav:environment', 'Episode cap reached; reset before stepping again');
            end
            obj.refresh_priorities();
            obj.step_count = obj.step_count + 1;
            rc = obj.config.reward;
            n = numel(obj.agents);
            rewards = rc.time_step * ones(1, n);
            info = struct('collisions_obstacle_step', 0, 'collisions_agent_agent_step', 0, ...
                'active_yield_events_step', 0, 'targets_reached_step', 0, ...
                'path_conflict_penalty_step', 0);
            before = reshape([obj.agents.position], 2, [])';
            % Occupancy of communicated (truth) paths, excluding the current cell.
            occ_before = obj.path_occupancy(true);
            [final, collided, rewards, info] = obj.resolve_positions(actions, rewards, info, before);
            info.collisions_agent_agent_step = sum(collided);
            rewards(collided) = rewards(collided) + rc.collision_agent;
            for k = 1:n
                obj.agents(k).position = final(k, :);
                obj.agents(k).previous_distance_to_goal = obj.agents(k).distance_to_goal;
                obj.refresh_path(k);
            end
            occ_after = obj.path_occupancy(false);
            priority = [obj.agents.priority];
            arrivals = [];
            for k = 1:n
                a = obj.agents(k);
                at_goal = isequal(a.position, a.goal);
                if isfinite(a.previous_distance_to_goal) && isfinite(a.distance_to_goal) && ~at_goal
                    rewards(k) = rewards(k) + (a.previous_distance_to_goal - a.distance_to_goal) ...
                        * rc.distance_improvement;
                end
                on_before = occ_before(cell_index(obj, before(k, :)), :);
                on_after_move = occ_before(cell_index(obj, a.position), :);
                was_on_priority = any(priority(on_before) < priority(k));
                if was_on_priority && ~isequal(before(k, :), a.position) ...
                        && ~any(priority(on_after_move) < priority(k))
                    rewards(k) = rewards(k) + rc.active_yield;
                    info.active_yield_events_step = info.active_yield_events_step + 1;
                end
                blocking = false;
                others = find(occ_after(cell_index(obj, a.position), :));
                for j = others
                    if j ~= k && priority(j) < priority(k) && panama_uav.environment.manhattan( ...
                            a.position, obj.agents(j).position) <= obj.communication_range
                        blocking = true;
                        break;
                    end
                end
                if at_goal
                    if ~a.ever_reached_goal
                        obj.agents(k).ever_reached_goal = true;
                        rewards(k) = rewards(k) + rc.goal;
                        arrivals(end + 1) = obj.step_count; %#ok<AGROW>
                        info.targets_reached_step = info.targets_reached_step + 1;
                    end
                    if blocking
                        rewards(k) = rewards(k) + rc.path_conflict;
                        info.path_conflict_penalty_step = info.path_conflict_penalty_step + 1;
                    else
                        rewards(k) = rewards(k) + rc.hold;
                    end
                elseif blocking
                    rewards(k) = rewards(k) + rc.path_conflict;
                    info.path_conflict_penalty_step = info.path_conflict_penalty_step + 1;
                end
            end
            obj.refresh_priorities();
            obj.communication.update(obj.agents, obj.step_count * obj.config.communication.seconds_per_step);
            snap = obj.communication.snapshot();
            ud = obj.uav.update(obj.uav.positions_to_xy_m(snap.uav_report_positions));
            obj.radio_snapshot = obj.uav.snapshot();
            info.goal_reached_steps_list = arrivals;
            info.agents_at_goal_step = sum(arrayfun(@(x) isequal(x.position, x.goal), obj.agents));
            info.agent_positions = reshape([obj.agents.position], 2, [])';
            info.uav_distance_moved_step = ud.distance_moved;
            info.uav_position = obj.uav.position;
            info.communication = snap;
            terminated = obj.all_agents_at_goals();
            truncated = obj.step_count >= obj.max_episode_steps && ~terminated;
            result = struct('observations', obj.observations(), 'rewards', rewards, ...
                'terminated', terminated, 'truncated', truncated, 'info', info);
        end
    end

    methods (Access = private)
        function refresh_path(obj, k)
            a = obj.agents(k);
            path = panama_uav.environment.astar_path(obj.grid, a.position, a.goal);
            obj.agents(k).path = path;
            if isempty(path)
                obj.agents(k).distance_to_goal = inf;
            else
                obj.agents(k).distance_to_goal = size(path, 1) - 1;
            end
            m = min(size(path, 1), obj.config.map.communicated_path_steps + 1);
            obj.communicated_paths{k} = path(1:m, :);
        end

        function refresh_priorities(obj)
            settled = obj.width * obj.height;
            for k = 1:numel(obj.agents)
                if obj.agents(k).ever_reached_goal
                    obj.agents(k).priority = settled + obj.agents(k).id * 1e-6;
                else
                    obj.agents(k).priority = obj.agents(k).distance_to_goal + obj.agents(k).id * 1e-6;
                end
            end
        end

        function occ = path_occupancy(obj, skip_settled)
            %PATH_OCCUPANCY (H*W)-by-N logical: cell lies on agent j's communicated path[1:].
            n = numel(obj.agents);
            occ = false(obj.height * obj.width, n);
            for j = 1:n
                if skip_settled && obj.agents(j).ever_reached_goal
                    continue;
                end
                p = obj.communicated_paths{j};
                if size(p, 1) > 1
                    occ(sub2ind([obj.height obj.width], p(2:end, 1) + 1, p(2:end, 2) + 1), j) = true;
                end
            end
        end

        function [starts, goals] = random_starts_and_goals(obj)
            %RANDOM_STARTS_AND_GOALS Shuffle free cells with the env's own stream
            %   and pop pairs from the end, as Python does with self.rng.shuffle.
            %   Same distribution as NumPy, different stream: inject starts/goals
            %   for episodes identical to Python's.
            %
            %   Known off-by-one, inherited from Python ON PURPOSE: the guard
            %   checks numel(cells) < num_agents, but an odd agent count pops
            %   num_agents + 1 cells (each pair pops two, the odd agent pops a
            %   start AND a goal). With exactly num_agents free cells and an odd
            %   count, Python raises IndexError (pop from empty list) and this
            %   port raises an index-out-of-bound error instead of the guard's
            %   panama_uav:environment message. It is kept so the port matches
            %   environment.py:_random_starts_and_goals; fix both together.
            %   RngTest/testOddAgentGuardOffByOneLikePython pins it.
            [rows, cols] = find(obj.grid' == 0);       % row-major order like np.argwhere
            cells = [cols - 1, rows - 1];
            if size(cells, 1) < obj.num_agents
                error('panama_uav:environment', 'Not enough traversable cells for the requested agents');
            end
            cells = cells(obj.rng.permutation(size(cells, 1)), :);
            [starts, goals] = panama_uav.environment.pop_starts_and_goals(cells, obj.num_agents);
        end

        function [final, collided, rewards, info] = resolve_positions(obj, actions, rewards, info, before)
            n = numel(obj.agents);
            intended = before;
            for k = 1:n
                action = 4;
                if k <= numel(actions)
                    action = actions(k);
                end
                if action >= 0 && action <= 4
                    delta = obj.ACTION_DELTAS(action + 1, :);
                else
                    delta = [0 0];
                end
                target = before(k, :) + delta;
                if obj.valid(target)
                    intended(k, :) = target;
                else
                    rewards(k) = rewards(k) + obj.config.reward.collision_obstacle;
                    info.collisions_obstacle_step = info.collisions_obstacle_step + 1;
                end
            end
            final = intended;
            collided = false(1, n);
            priority = [obj.agents.priority];
            while true
                % First target (in order of first appearance) claimed by several agents.
                [~, first_seen, group] = unique(final, 'rows', 'first');
                order = sort(first_seen)';
                vertex = [];
                for f = order
                    ids = find(group == group(f))';
                    if numel(ids) > 1
                        vertex = ids;
                        break;
                    end
                end
                if ~isempty(vertex)
                    stayers = vertex(all(final(vertex, :) == before(vertex, :), 2));
                    candidates = stayers;
                    if isempty(candidates)
                        candidates = vertex;
                    end
                    [~, w] = min(priority(candidates));
                    winner = candidates(w);
                    for id = vertex
                        if id ~= winner
                            final(id, :) = before(id, :);
                        end
                    end
                    collided(vertex) = true;
                    continue;
                end
                swap = [];
                for i = 1:n
                    for j = i + 1:n
                        if isequal(final(i, :), before(j, :)) && isequal(final(j, :), before(i, :))
                            swap = [i j];
                            break;
                        end
                    end
                    if ~isempty(swap)
                        break;
                    end
                end
                if ~isempty(swap)
                    final(swap, :) = before(swap, :);
                    collided(swap) = true;
                    continue;
                end
                break;
            end
        end

        function tf = valid(obj, p)
            tf = p(1) >= 0 && p(1) < obj.height && p(2) >= 0 && p(2) < obj.width ...
                && obj.grid(p(1) + 1, p(2) + 1) == 0;
        end
    end
end

function idx = cell_index(obj, p)
    idx = sub2ind([obj.height obj.width], p(1) + 1, p(2) + 1);
end
