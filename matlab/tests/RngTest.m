classdef RngTest < matlab.unittest.TestCase
    % Seedless and seeded episode generation (no injected draws). Python
    % semantics (environment.py:112,191; transport.py:schedule_episode):
    %   reset() advances the env's own generator; reset(seed) replaces it;
    %   reservation windows always come from a fresh generator seeded with
    %   the base seed (or the explicit seed).
    methods (Test)
        function testPortableStreamMatchesReference(tc)
            % Same stream on MATLAB, Octave and the Python reference in make_fixtures.py.
            fx = load_fixture('rng');
            streams = as_cell(fx.streams);
            for k = 1:numel(streams)
                s = streams{k};
                g = panama_uav.util.Xorshift128(s.seed);
                got = arrayfun(@(i) double(g.next_uint32()), 1:8);
                tc.verifyEqual(got, reshape(s.uint32, 1, []), sprintf('seed %d uint32', s.seed));
                tc.verifyEqual(arrayfun(@(i) g.rand(), 1:4), ...
                    panama_uav.util.hex_to_double(reshape(s.rand_hex, 1, [])), sprintf('seed %d rand', s.seed));
                tc.verifyEqual(g.permutation(10), reshape(s.permutation, 1, []), sprintf('seed %d perm', s.seed));
                tc.verifyEqual(g.choice(249, 2), reshape(s.choice, 1, []), sprintf('seed %d choice', s.seed));
            end
        end
        function testMarsagliaPublishedReference(tc)
            % Independent of rng.json: Marsaglia (2003), "Xorshift RNGs", J. Stat.
            % Softw. 8(14), xor128 with its default state. These first ten
            % outputs are the widely reproduced reference sequence for that
            % state (the same values appear in independent C, Rust and Ruby
            % implementations); they are hard-coded, not generated.
            g = panama_uav.util.Xorshift128.from_state([123456789 362436069 521288629 88675123]);
            expected = [3701687786 458299110 2500872618 3633119408 516391518 ...
                        2377269574 2599949379 717229868 137866584 395339113];
            got = arrayfun(@(i) double(g.next_uint32()), 1:10);
            tc.verifyEqual(got, expected);
            tc.verifyError(@() panama_uav.util.Xorshift128.from_state([0 0 0 0]), 'panama_uav:rng');
        end
        function testOddAgentGuardOffByOneLikePython(tc)
            % Python checks len(cells) < num_agents but an odd count pops
            % num_agents + 1 cells. The port inherits this on purpose (driven
            % through reset(), which samples starts/goals when none are injected):
            %   3 agents, 2 free cells -> guard (Python RuntimeError)
            %   3 agents, 3 free cells -> index error past the guard (Python IndexError)
            %   3 agents, 4 free cells -> fine;  2 agents, 2 free cells -> fine
            env = make_env(3, 1);
            env.grid = free_grid(size(env.grid), 2);
            tc.verifyError(@() env.reset(), 'panama_uav:environment');
            env.grid = free_grid(size(env.grid), 3);
            id = 'none';
            where = '';
            try
                env.reset();
            catch err
                id = err.identifier;
                where = err.stack(1).name;
            end
            tc.verifyTrue(~isempty(strfind(where, 'random_starts_and_goals')), ...
                'the failure must come from popping cells, as in Python');
            tc.verifyFalse(strcmp(id, 'none'), '3 agents on 3 cells must fail like Python');
            tc.verifyFalse(strcmp(id, 'panama_uav:environment'), 'the guard must not catch it (inherited off-by-one)');
            env.grid = free_grid(size(env.grid), 4);
            [s, g] = episode(env);
            tc.verifyEqual(size(s), [3 2]);
            tc.verifyFalse(ismember(g(3, :), s, 'rows'));
            env2 = make_env(2, 1);
            env2.grid = free_grid(size(env2.grid), 2);
            [s, ~] = episode(env2);
            tc.verifyEqual(size(s), [2 2]);
        end
        function testStartGoalPopOrderLikePython(tc)
            % Pins Python's pop order on a 6-cell grid with an independent
            % copy of the env stream: cells are shuffled with the env's
            % generator, then each pair pops (first=end, second=end-1) with
            % goals swapped, and the odd agent gets start=end, goal=end-1.
            for n = [3 5]
                for seed = [1 4 9]
                    env = make_env(n, seed);
                    env.grid = free_grid(size(env.grid), 6);
                    [s, g] = episode(env);
                    [rows, cols] = find(env.grid' == 0);
                    cells = [cols - 1, rows - 1];
                    ref = panama_uav.util.Xorshift128(seed);
                    cells = cells(ref.permutation(size(cells, 1)), :);
                    for k = 1:floor(n / 2)
                        tc.verifyEqual(s(2 * k - 1, :), cells(end, :));
                        tc.verifyEqual(s(2 * k, :), cells(end - 1, :));
                        cells = cells(1:end - 2, :);
                    end
                    label = sprintf('odd agent, %d agents, seed %d', n, seed);
                    tc.verifyEqual(s(n, :), cells(end, :), [label ' start']);
                    tc.verifyEqual(g(n, :), cells(end - 1, :), [label ' goal']);
                end
            end
        end
        function testSeedlessResetsAdvance(tc)
            env = make_env(4, 123);
            [s1, g1, w1] = episode(env);
            [s2, g2, w2] = episode(env);
            [s3, ~, ~] = episode(env);
            tc.verifyFalse(isequal(s1, s2), 'second seedless reset repeated the first episode');
            tc.verifyFalse(isequal(s2, s3), 'third seedless reset repeated the second episode');
            tc.verifyFalse(isequal(g1, g2));
            % Windows use the base seed every time, exactly as in Python.
            tc.verifyEqual(w1, w2);
        end
        function testSameSeedSequenceReproduces(tc)
            a = make_env(4, 77);
            b = make_env(4, 77);
            for k = 1:3
                [sa, ga, wa] = episode(a);
                [sb, gb, wb] = episode(b);
                tc.verifyEqual(sa, sb, sprintf('episode %d starts', k));
                tc.verifyEqual(ga, gb, sprintf('episode %d goals', k));
                tc.verifyEqual(wa, wb, sprintf('episode %d windows', k));
            end
            c = make_env(4, 78);
            [sc, ~, ~] = episode(c);
            [sa1, ~, ~] = episode(make_env(4, 77));
            tc.verifyFalse(isequal(sc, sa1), 'different seeds gave the same episode');
        end
        function testExplicitSeedResetsStream(tc)
            fresh = make_env(4, 5);
            [s_ref, g_ref, w_ref] = episode(fresh);
            env = make_env(4, 99);
            episode(env);
            episode(env);
            [s, g, w] = episode(env, 5);
            tc.verifyEqual(s, s_ref);
            tc.verifyEqual(g, g_ref);
            tc.verifyEqual(w, w_ref);
            % After the reseed, a seedless reset continues the seed-5 stream.
            [s_next_ref, ~, ~] = episode(fresh);
            [s_next, ~, ~] = episode(env);
            tc.verifyEqual(s_next, s_next_ref);
        end
        function testEpisodeStructureMatchesPython(tc)
            for n = [2 3 6 8]
                env = make_env(n, 10 + n);
                for rep = 1:5
                    [s, g, w] = episode(env);
                    tc.verifyEqual(size(unique(s, 'rows'), 1), n, 'starts must be distinct');
                    tc.verifyTrue(all(env.grid(sub2ind(size(env.grid), s(:, 1) + 1, s(:, 2) + 1)) == 0));
                    tc.verifyTrue(all(env.grid(sub2ind(size(env.grid), g(:, 1) + 1, g(:, 2) + 1)) == 0));
                    % Python pops pairs and swaps them: goals(2k-1)=starts(2k), goals(2k)=starts(2k-1).
                    for k = 1:floor(n / 2)
                        tc.verifyEqual(g(2 * k - 1, :), s(2 * k, :));
                        tc.verifyEqual(g(2 * k, :), s(2 * k - 1, :));
                    end
                    if mod(n, 2)
                        tc.verifyFalse(ismember(g(n, :), s, 'rows'), 'odd agent goal must be a fresh cell');
                    end
                    c = env.config.communication;
                    for a = 1:n
                        tc.verifyTrue(size(w{a}, 1) >= c.windows_min && size(w{a}, 1) <= c.windows_max);
                        steps = w{a}(:, 1)' / c.seconds_per_step;
                        tc.verifyTrue(all(steps >= 1 & steps <= 249) && all(diff(steps) > 0));
                        tc.verifyEqual(w{a}(:, 2) - w{a}(:, 1), c.reservation_steps * c.seconds_per_step * ones(size(w{a}, 1), 1));
                    end
                end
            end
        end
    end
end

function env = make_env(n, seed)
    c = panama_uav.config.load_config(fullfile(repo_root(), 'configs', 'base.toml'));
    env = panama_uav.environment.ExperimentEnvironment(c, 'maps/random-32-32-10.map', n, 250, seed);
end

function [starts, goals, windows] = episode(env, seed)
    if nargin < 2
        env.reset();
    else
        env.reset('seed', seed);
    end
    starts = reshape([env.agents.position], 2, [])';
    goals = reshape([env.agents.goal], 2, [])';
    windows = env.communication.transport.windows;
end

function g = free_grid(sz, free)
% All obstacles except the first FREE cells in row-major order (like grid.flat).
    g = ones(sz, 'uint8');
    t = g';
    t(1:free) = 0;
    g = t';
end
