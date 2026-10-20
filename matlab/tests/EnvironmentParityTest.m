classdef EnvironmentParityTest < matlab.unittest.TestCase
    % Parity: full environment rollouts (dynamics, rewards, observations,
    % information staleness, controlled and physical transport, UAV)
    % against Python. NumPy draws (starts/goals, reservation windows) are
    % injected. Every case checks the wire size of each generated and
    % delivered message (mission payloads, M1b-2). The physical cases also
    % compare the whole transport log (link service, handovers, traces),
    % every counter and the final clock bit for bit, so a wire size one
    % byte off shows up as a different service time.
    methods (Test)
        function testFreshFourAgents(tc), check_case(tc, 'fresh_a4'); end
        function testFreshEightAgents(tc), check_case(tc, 'fresh_a8'); end
        function testStaleAllUavDelay5(tc), check_case(tc, 'stale_all_uav_d5'); end
        function testStaleAllCloudDelay10(tc), check_case(tc, 'stale_all_cloud_d10'); end
        function testStaleTaskDelay20(tc), check_case(tc, 'stale_task_d20'); end
        function testStaleIntentionsPrioritiesTwoWindows(tc), check_case(tc, 'stale_prio_int_d2'); end
        function testPerfectProfileIgnoresStaleness(tc), check_case(tc, 'perfect_stale'); end
        function testNoContentionEdgeProcessing(tc), check_case(tc, 'no_contention'); end
        function testCloudProcessingDelay(tc), check_case(tc, 'cloud_processing'); end
        function testTruncationAtShortCap(tc), check_case(tc, 'truncated_cap12'); end
        function testPhysicalFresh(tc), check_case(tc, 'physical_fresh_a4', 'env_physical'); end
        function testPhysicalStaleAllUav(tc), check_case(tc, 'physical_stale_all_uav', 'env_physical'); end
        function testPhysicalSlowAccessEightAgents(tc), check_case(tc, 'physical_slow_access_a8', 'env_physical'); end
        function testPhysicalCloudHandovers(tc), check_case(tc, 'physical_cloud_handover', 'env_physical'); end
        function testPhysicalFragmented(tc), check_case(tc, 'physical_fragmented', 'env_physical'); end
        function testPhysicalDelayTraces(tc), check_case(tc, 'physical_traces', 'env_physical'); end
        function testPhysicalTruncationAtShortCap(tc), check_case(tc, 'physical_truncated_cap10', 'env_physical'); end
    end
end

function check_case(tc, name, group)
    if nargin < 3
        group = 'env';
    end
    persistent fx
    if isempty(fx)
        fx = struct();
    end
    if ~isfield(fx, group)
        fx.(group) = load_fixture(group);
    end
    k = fx.(group).(name);
    [env, ~, obs0, info0] = make_env(k);
    frames = as_cell(k.frames);
    n = k.agents;
    tc.verifyEqual(info0.max_initial_astar_distance, k.info0.max_initial_astar_distance, [name, ' reset info']);
    spatial0 = per_agent(k.reset_observations.spatial_ones, n);
    for a = 1:n
        tc.verifyEqual(python_flat_ones(obs0(a).spatial), reshape(spatial0{a}, 1, []), ...
            sprintf('%s reset agent %d spatial', name, a - 1));
        tc.verifyEqual(obs0(a).vector, single(reshape(k.reset_observations.vector(a, :), 1, [])), ...
            sprintf('%s reset agent %d vector', name, a - 1));
    end

    for f = 1:numel(frames)
        fr = frames{f};
        label = sprintf('%s step %d', name, f);
        r = env.step(reshape(fr.actions, 1, []));
        tc.verifyEqual(r.info.agent_positions, reshape(fr.positions, [], 2), [label, ' positions']);
        tc.verifyEqual(r.rewards, reshape(fr.rewards, 1, []), 'AbsTol', 1e-12, [label, ' rewards']);
        tc.verifyEqual(r.terminated, fr.terminated, [label, ' terminated']);
        tc.verifyEqual(r.truncated, fr.truncated, [label, ' truncated']);
        tc.verifyEqual(r.info.collisions_obstacle_step, fr.collisions_obstacle, [label, ' obstacle']);
        tc.verifyEqual(r.info.collisions_agent_agent_step, fr.collisions_agent, [label, ' agent collisions']);
        tc.verifyEqual(r.info.path_conflict_penalty_step, fr.path_conflict, [label, ' path conflict']);
        tc.verifyEqual(r.info.targets_reached_step, fr.targets, [label, ' targets']);
        tc.verifyEqual(r.info.agents_at_goal_step, fr.at_goal, [label, ' at goal']);
        tc.verifyEqual(r.info.uav_position, reshape(fr.uav, 1, []), 'AbsTol', 1e-12, [label, ' uav']);
        tc.verifyEqual(r.info.uav_distance_moved_step, fr.uav_moved, 'AbsTol', 1e-12, [label, ' uav moved']);
        tc.verifyEqual(r.info.communication.information_age, reshape(fr.ages, n, 3), 'AbsTol', 1e-12, ...
            [label, ' information age']);
        tc.verifyEqual(r.info.communication.uav_report_age_seconds, reshape(fr.report_age, 1, []), ...
            'AbsTol', 1e-12, [label, ' report age']);
        tc.verifyEqual([env.agents.priority], reshape(fr.priorities, 1, []), 'AbsTol', 1e-12, [label, ' priority']);
        guidance = per_agent(fr.guidance, n);
        spatial = per_agent(fr.spatial_ones, n);
        vec = fr.vector;
        for a = 1:n
            tc.verifyEqual(r.info.communication.cached_guidance{a}, reshape(guidance{a}, [], 2), ...
                sprintf('%s agent %d guidance', label, a - 1));
            tc.verifyEqual(python_flat_ones(r.observations(a).spatial), reshape(spatial{a}, 1, []), ...
                sprintf('%s agent %d spatial', label, a - 1));
            % Compare at float32: Octave's jsondecode can be 1 ulp off in double.
            tc.verifyEqual(r.observations(a).vector, single(reshape(vec(a, :), 1, [])), ...
                sprintf('%s agent %d vector', label, a - 1));
        end
    end
    check_log(tc, name, env.communication.transport, k);
    if isfield(k, 'full_log')
        check_full_log(tc, name, env.communication.transport, k);
    end
    if frames{end}.truncated
        tc.verifyEqual(env.step_count, k.cap, [name, ' cap']);
        tc.verifyError(@() env.step(4 * ones(1, n)), 'panama_uav:environment');
    end
end

function [env, c, obs0, info0] = make_env(k)
    c = panama_uav.config.load_config(fullfile(repo_root(), 'configs', 'base.toml'));
    comm = k.communication;
    names = fieldnames(comm);
    args = {};
    for j = 1:numel(names)
        v = comm.(names{j});
        if strcmp(names{j}, 'stale_information')
            v = reshape(cellstr(v), 1, []);
        elseif any(strcmp(names{j}, {'uplink_trace', 'downlink_trace'}))
            v = fullfile(repo_root(), 'matlab', 'tests', 'fixtures', v);
        end
        args = [args, {names{j}, v}]; %#ok<AGROW>
    end
    c = panama_uav.config.with_communication(c, args{:});
    env = panama_uav.environment.ExperimentEnvironment(c, 'maps/random-32-32-10.map', k.agents, k.cap, k.seed);
    windows = fixture_windows(k.windows, k.agents);
    [obs0, info0] = env.reset('starts', reshape(k.starts, [], 2), 'goals', reshape(k.goals, [], 2), 'windows', windows);
end

function idx = python_flat_ones(spatial)
% Indices of ones in Python's (channel, row, col) C-order flattening.
    [r, c, ch] = ind2sub(size(spatial), find(spatial));
    n = size(spatial, 1);
    idx = sort(((ch - 1) * n * n + (r - 1) * n + (c - 1))');
    if isempty(idx)
        idx = zeros(1, 0);
    end
end

function check_log(tc, name, transport, k)
    keep = {'scheduled_reservation', 'reservation_exposure', 'buffered', 'generated', 'delivered'};
    got = transport.log(cellfun(@(e) any(strcmp(e.event, keep)), transport.log));
    want = as_cell(k.log);
    tc.verifyEqual(numel(got), numel(want), [name, ' transport log length']);
    fields = {'time', 'agent', 'id', 'release', 'ready_at', 'source_time', 'version', 'bytes'};
    for j = 1:min(numel(got), numel(want))
        g = got{j};
        w = want{j};
        tc.verifyEqual(g.event, w.event, sprintf('%s log %d event', name, j));
        if isfield(w, 'kind')
            tc.verifyEqual(g.kind, w.kind, sprintf('%s log %d kind', name, j));
        end
        for f = fields
            if isfield(w, f{1})
                tc.verifyEqual(g.(f{1}), w.(f{1}), 'AbsTol', 1e-12, sprintf('%s log %d %s', name, j, f{1}));
            end
        end
    end
    tc.verifyEqual(transport.counters.messages_generated, k.counters.messages_generated, [name, ' generated']);
    tc.verifyEqual(transport.counters.messages_delivered, k.counters.messages_delivered, [name, ' delivered']);
    tc.verifyEqual(transport.counters.exposed_messages, k.counters.exposed_messages, [name, ' exposed']);
end

function check_full_log(tc, name, transport, k)
    logs = as_cell(k.full_log);
    tc.verifyEqual(numel(transport.log), numel(logs), [name, ' full log length']);
    for j = 1:min(numel(transport.log), numel(logs))
        check_tagged(tc, transport.log{j}, logs{j}, sprintf('%s full log %d', name, j));
    end
    counters = fieldnames(transport.counters);
    want = k.full_counters;
    tc.verifyTrue(all(ismember(fieldnames(want), counters)), [name, ' counter names']);
    for j = 1:numel(counters)
        expected = 0;
        if isfield(want, counters{j})
            expected = want.(counters{j});
        end
        tc.verifyEqual(transport.counters.(counters{j}), expected, [name, ' counter ', counters{j}]);
    end
    tc.verifyEqual(typecast(transport.now, 'uint64'), typecast(panama_uav.util.hex_to_double(k.now), 'uint64'), ...
        [name, ' now']);
end
