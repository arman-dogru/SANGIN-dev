classdef Golden01Test < matlab.unittest.TestCase
    % The frozen PANAMA 0.1 golden trace (tests/fixtures/zero_delay_01.json,
    % used by tests/test_environment.py) replayed in MATLAB for the default
    % config and for both mission routes with all inputs stale at zero delay.
    % Starts/goals from np.random.default_rng(123) come from golden01.json.
    methods (Test)
        function testDefaultConfig(tc), replay(tc, ''); end
        function testUavRouteZeroDelay(tc), replay(tc, 'uav'); end
        function testCloudRouteZeroDelay(tc), replay(tc, 'cloud'); end
    end
end

function replay(tc, route)
    golden = jsondecode(panama_uav.util.read_text(fullfile(repo_root(), 'tests', 'fixtures', 'zero_delay_01.json')));
    draws = load_fixture('golden01');
    c = panama_uav.config.load_config(fullfile(repo_root(), 'configs', 'base.toml'));
    if ~isempty(route)
        c = panama_uav.config.with_communication(c, 'mission_route', route, ...
            'stale_information', {'task', 'intentions', 'priorities'}, 'delay_steps', 0);
    end
    env = panama_uav.environment.ExperimentEnvironment(c, 'maps/random-32-32-10.map', 4, 250, 123);
    env.reset('starts', reshape(draws.starts, [], 2), 'goals', reshape(draws.goals, [], 2), ...
        'windows', fixture_windows(draws.windows, 4));
    frames = as_cell(golden.frames);
    tc.verifyEqual(numel(frames), 40);
    for f = 1:numel(frames)
        fr = frames{f};
        actions = cellfun(@(k) fr.actions.(k), fieldnames(fr.actions))';
        r = env.step(actions);
        label = sprintf('route %s frame %d', route, f);
        tc.verifyEqual(r.info.agent_positions, fr.positions, [label, ' positions']);
        rewards = cellfun(@(k) fr.rewards.(k), fieldnames(fr.rewards))';
        tc.verifyEqual(r.rewards, rewards, 'AbsTol', 1e-12, [label, ' rewards']);
        tc.verifyEqual(r.terminated, fr.terminated, [label, ' terminated']);
        names = fieldnames(fr.spatial);
        for a = 1:4
            expected = permute(fr.spatial.(names{a}), [2 3 1]);
            tc.verifyEqual(r.observations(a).spatial, single(expected), sprintf('%s agent %d spatial', label, a - 1));
            tc.verifyEqual(r.observations(a).vector, single(reshape(fr.vector.(names{a}), 1, [])), ...
                sprintf('%s agent %d vector', label, a - 1));
        end
        tc.verifyEqual(r.info.uav_position, reshape(fr.uav, 1, []), 'AbsTol', 1e-9, [label, ' uav']);
    end
end
