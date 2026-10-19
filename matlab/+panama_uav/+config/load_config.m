function c = load_config(path)
%LOAD_CONFIG Load and validate a study config (src/panama_uav/config.py:load_config).
%   C = panama_uav.config.load_config(PATH) reads a configs/*.toml file with
%   panama_uav.util.toml_decode, overlays it on panama_uav.config.defaults
%   and applies the same study checks as Python. The project root is the
%   parent of the config's directory.
    if nargin < 1
        path = fullfile('configs', 'base.toml');
    end
    path = panama_uav.util.absolute_path(path);
    raw = panama_uav.util.toml_decode(panama_uav.util.read_text(path));
    root = fileparts(fileparts(path));
    allowed = {'map', 'reward', 'training', 'curriculum', 'uav', 'communication', 'evaluation'};
    if ~isempty(setdiff(fieldnames(raw), allowed))
        error('panama_uav:config', ...
            'Legacy or unknown configuration sections; use a new communication-study config');
    end
    c = panama_uav.config.defaults(root);
    sections = {'map', 'reward', 'training', 'uav', 'communication', 'evaluation'};
    for k = 1:numel(sections)
        name = sections{k};
        if isfield(raw, name)
            c.(name) = panama_uav.config.overlay(c.(name), raw.(name), name);
        end
    end
    if isfield(raw, 'curriculum') && isfield(raw.curriculum, 'stages') && ~isempty(raw.curriculum.stages)
        stages = c.curriculum([]);
        for k = 1:numel(raw.curriculum.stages)
            stages(k) = panama_uav.config.stage(raw.curriculum.stages{k});
        end
        c.curriculum = stages;
    end
    panama_uav.config.validate_transport(c.communication);
    d = panama_uav.config.defaults(root);
    bad = ~isequal([c.curriculum.num_agents], [2 4 6 8]);
    for s = c.curriculum
        bad = bad || ~strcmp(s.map_path, 'maps/random-32-32-10.map') || s.max_episode_steps ~= 250 ...
            || s.min_episodes < 500 || s.graduation_success_rate < 0.95;
    end
    if bad
        error('panama_uav:config', ['Study requires fixed map, phases 2/4/6/8, 250 steps, ', ...
            'minimum 500 episodes and 95% qualification']);
    end
    if c.training.validation_episodes ~= 200 || c.training.validation_interval_episodes ~= 250 ...
            || c.training.model_broadcast_steps ~= 16
        error('panama_uav:config', ...
            'Study requires 200 validation episodes every 250 episodes, snapshots every 16 steps');
    end
    m = c.map;
    m.meters_per_cell = 1.0;
    if ~isequal(c.reward, d.reward) || ~isequal(m, d.map)
        error('panama_uav:config', 'This study retains 0.1 task rewards and observations');
    end
    if ~(0 < c.training.budget_seconds && c.training.budget_seconds <= 86400)
        error('panama_uav:config', 'A condition allocation must be positive and at most 24 hours');
    end
end
