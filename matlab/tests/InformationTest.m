classdef InformationTest < matlab.unittest.TestCase
    % Guidance consumption and cache monotonicity (tests/test_environment.py equivalents).
    methods (Test)
        function testGuidanceConsumption(tc)
            fx = load_fixture('guidance');
            g = panama_uav.information.Guidance([1 1; 1 2; 1 3; 2 3], 3);
            visits = [1 1; 1 2; 2 2; 2 3];
            seq = as_cell(fx.sequence);
            for k = 1:4
                tc.verifyEqual(g.consume(visits(k, :)), reshape(seq{k}, [], 2));
            end
            tc.verifyEqual(g.reported_distance, 3);
        end
        function testCacheCannotReverse(tc)
            c = panama_uav.information.InformationCache();
            tc.verifyTrue(c.accept(2, 'fresh', 2));
            tc.verifyFalse(c.accept(1, 'late', 3));
            tc.verifyFalse(c.accept(2, 'old', 1));
            tc.verifyEqual(c.value, 'fresh');
            tc.verifyEqual(c.age(5), 3);
        end
        function testPhysicalMissionPayloadsAreExplicitlyNotImplemented(tc)
            % The physical profile itself is ported (TransportTest), but the
            % mission payloads' pickle sizes (int-keyed dicts, Guidance, arrays
            % standing for tuples) are milestone M1b-2, so the first UAV
            % report fails loudly.
            c = panama_uav.config.load_config(fullfile(repo_root(), 'configs', 'base.toml'));
            c = panama_uav.config.with_communication(c, 'profile', 'physical');
            env = panama_uav.environment.ExperimentEnvironment(c, 'maps/random-32-32-10.map', 2, 250, 1);
            env.reset();
            tc.verifyError(@() env.step(4 * ones(1, 2)), 'panama_uav:notImplemented');
        end
    end
end
