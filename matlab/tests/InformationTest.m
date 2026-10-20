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
        function testMissionWireSizesMatchPython(tc)
            % encode_size(mission_wire(kind, payload)) for MATLAB payloads
            % built by MissionCommunication.report/value from five agents
            % whose coordinates pass 255 and 65535, with an empty path and
            % infinite distance and priority, vs len(transport.encode(...))
            % of the payloads information.py builds from the same agents.
            fx = load_fixture('mission_wire');
            c = panama_uav.config.load_config(fullfile(repo_root(), 'configs', 'base.toml'));
            env = panama_uav.environment.ExperimentEnvironment(c, 'maps/random-32-32-10.map', 2, 250, 1);
            env.reset();
            mc = env.communication;
            spec = as_cell(fx.agents);
            n = numel(spec);
            reports = cell(1, n);
            for k = 1:n
                a = spec{k};
                agent = struct('id', a.id, 'position', reshape(a.position, 1, 2), ...
                    'goal', reshape(a.goal, 1, 2), 'path', reshape(double(a.path), [], 2), ...
                    'distance_to_goal', panama_uav.util.fixture_number(a.distance), ...
                    'priority', panama_uav.util.fixture_number(a.priority), ...
                    'ever_reached_goal', a.completed);
                reports{k} = mc.report(agent);
            end
            sources = reshape(fx.sources, 1, []);
            cases = as_cell(fx.cases);
            tc.verifyEqual(numel(cases), 38);
            for k = 1:numel(cases)
                w = cases{k};
                switch w.kind
                    case 'report'
                        payload = reports{w.agent + 1};
                    case 'mission_request'
                        payload = struct('field', w.field, 'report', reports{w.agent + 1});
                    case 'mission_compute'
                        payload = struct('field', w.field, 'reports', {reports}, 'sources', sources);
                    case 'information'
                        if strcmp(w.field, 'task')
                            ids = w.agent;
                            times = sources(w.agent + 1);
                        else
                            ids = 0:n - 1;
                            times = sources;
                        end
                        payload = struct('field', w.field, 'value', {mc.value(w.field, w.agent, reports)}, ...
                            'source_ids', ids, 'source_times', times);
                end
                got = panama_uav.transport.encode_size(panama_uav.information.mission_wire(w.kind, payload));
                tc.verifyEqual(got, w.size, sprintf('case %d (%s)', k, w.kind));
            end
        end
    end
end
