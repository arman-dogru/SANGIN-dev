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
