function s = load_scenario(path, maps_dir, num_agents)
%LOAD_SCENARIO Read a MovingAI .scen file (src/panama_uav/scenarios.py:load_scenario).
%   S = panama_uav.scenarios.load_scenario(PATH, MAPS_DIR, NUM_AGENTS)
%   returns a struct with fields path, map_path, name, starts and goals.
%   starts/goals are N-by-2 [row col] in Python's zero-based convention.
    if nargin < 3
        num_agents = [];
    end
    text = panama_uav.util.read_text(path);
    lines = regexp(text, '\r?\n', 'split');
    starts = zeros(0, 2);
    goals = zeros(0, 2);
    map_name = '';
    for k = 1:numel(lines)
        parts = strsplit(strtrim(lines{k}));
        if numel(parts) < 9 || isempty(parts{1}) || ~all(isstrprop(parts{1}, 'digit'))
            continue;
        end
        if isempty(map_name)
            map_name = parts{2};
        end
        v = str2double(parts(5:8));
        starts(end + 1, :) = [v(2) v(1)]; %#ok<AGROW>
        goals(end + 1, :) = [v(4) v(3)]; %#ok<AGROW>
        if ~isempty(num_agents) && size(starts, 1) >= num_agents
            break;
        end
    end
    if isempty(starts)
        error('panama_uav:scenario', 'No agent rows found in %s', path);
    end
    if ~endsWith(map_name, '.map')
        map_name = [map_name, '.map'];
    end
    [~, base, ext] = fileparts(strrep(map_name, '\', '/'));
    map_path = fullfile(maps_dir, [base, ext]);
    if ~exist(map_path, 'file')
        error('panama_uav:scenario', 'Scenario map not found: %s', map_path);
    end
    [~, name] = fileparts(path);
    s = struct('path', path, 'map_path', map_path, 'name', name, 'starts', starts, 'goals', goals);
end
