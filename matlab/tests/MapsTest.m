classdef MapsTest < matlab.unittest.TestCase
    % Parity: maps, scenarios and A* against the Python implementation.
    methods (Test)
        function testAllMapsMatchPython(tc)
            fx = load_fixture('maps');
            maps = as_cell(fx.maps);
            tc.verifyEqual(numel(maps), 13);
            for k = 1:numel(maps)
                g = panama_uav.scenarios.load_map(fullfile(repo_root(), maps{k}.file));
                tc.verifyEqual(size(g), reshape(maps{k}.shape, 1, []), maps{k}.file);
                ones_rowmajor = find(g')' - 1;    % Python C-order flat indices
                tc.verifyEqual(ones_rowmajor, reshape(maps{k}.obstacles, 1, []), maps{k}.file);
            end
        end
        function testScenariosMatchPython(tc)
            fx = load_fixture('maps');
            scens = as_cell(fx.scenarios);
            for k = 1:numel(scens)
                s = panama_uav.scenarios.load_scenario(fullfile(repo_root(), scens{k}.file), ...
                    fullfile(repo_root(), 'maps'), 8);
                [~, b, e] = fileparts(s.map_path);
                tc.verifyEqual([b e], scens{k}.map);
                tc.verifyEqual(s.starts, scens{k}.starts);
                tc.verifyEqual(s.goals, scens{k}.goals);
            end
        end
        function testMissingMarkerRejected(tc)
            path = [tempname, '.map'];
            fid = fopen(path, 'w'); fprintf(fid, 'type octile\nheight 1\n'); fclose(fid);
            tc.verifyError(@() panama_uav.scenarios.load_map(path), 'panama_uav:map');
            delete(path);
        end
        function testAStarNeighbourOrderOnTies(tc)
            % Up/down and left/right detours tie; Python expands up, down, left, right.
            fx = load_fixture('astar');
            cases = as_cell(fx.tie_cases);
            tc.verifyEqual(numel(cases), 7);
            for k = 1:numel(cases)
                g = uint8(cases{k}.grid);
                p = panama_uav.environment.astar_path(g, cases{k}.start, cases{k}.goal);
                tc.verifyEqual(p, reshape(cases{k}.path, [], 2), sprintf('tie case %d', k));
            end
        end
        function testAStarMatchesPython(tc)
            fx = load_fixture('astar');
            g = panama_uav.scenarios.load_map(fullfile(repo_root(), fx.map));
            cases = as_cell(fx.cases);
            for k = 1:numel(cases)
                p = panama_uav.environment.astar_path(g, cases{k}.start, cases{k}.goal);
                tc.verifyEqual(p, reshape(cases{k}.path, [], 2), sprintf('case %d', k));
            end
        end
    end
end
