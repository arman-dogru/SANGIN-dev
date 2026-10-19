function out = discover_scenarios(directories, maps_dir)
%DISCOVER_SCENARIOS All .scen files in DIRECTORIES, sorted by name (scenarios.py).
    out = {};
    if ischar(directories)
        directories = {directories};
    end
    for d = 1:numel(directories)
        files = dir(fullfile(directories{d}, '*.scen'));
        names = sort({files.name});
        for k = 1:numel(names)
            out{end + 1} = panama_uav.scenarios.load_scenario( ...
                fullfile(directories{d}, names{k}), maps_dir); %#ok<AGROW>
        end
    end
end
