function s = stage(fields)
%STAGE CurriculumStage with defaults (src/panama_uav/config.py:CurriculumStage).
    s = struct('name', '', 'map_path', 'maps/random-32-32-10.map', 'num_agents', 2, ...
        'max_episode_steps', 250, 'min_episodes', 500, 'max_episodes', 200000, ...
        'graduation_success_rate', 0.95);
    if nargin > 0
        s = panama_uav.config.overlay(s, fields, 'CurriculumStage');
    end
    if isempty(s.name)
        error('panama_uav:config', 'CurriculumStage requires a name');
    end
end
