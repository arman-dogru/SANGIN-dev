classdef ScaffoldTest < matlab.unittest.TestCase
    % Every not-yet-ported entry point fails loudly with panama_uav:notImplemented.
    methods (Test)
        function testStubMethodsOnPortedClasses(tc)
            c = panama_uav.config.load_config(fullfile(repo_root(), 'configs', 'base.toml'));
            env = panama_uav.environment.ExperimentEnvironment(c, 'maps/random-32-32-10.map', 2, 250, 1);
            env.reset();
            tc.verifyError(@() env.prepare_decision(0.1), 'panama_uav:notImplemented');
            tc.verifyError(@() env.communication.prepare_decision(env.agents, 0, 0.1), 'panama_uav:notImplemented');
            [spatial, vector_length] = env.observation_shape();
            tc.verifyEqual(spatial, [15 15 3]);
            tc.verifyEqual(vector_length, 12);
            t = c.communication;
            t.profile = 'physical';
            t.leo_timeline = 'leo/timeline.npz';
            tc.verifyError(@() panama_uav.transport.Transport(t), 'panama_uav:notImplemented');
            tc.verifyError(@() env.reset('start', [0 0]), 'panama_uav:options');
        end
        function testStubsRaiseNotImplemented(tc)
            here = fileparts(fileparts(mfilename('fullpath')));
            files = list_m(fullfile(here, '+panama_uav'));
            stubs = 0;
            for k = 1:numel(files)
                text = panama_uav.util.read_text(files{k});
                if isempty(strfind(text, 'Status: stub'))
                    continue;
                end
                stubs = stubs + 1;
                name = qualified_name(here, files{k});
                tc.verifyError(@() feval(name), 'panama_uav:notImplemented', name);
            end
            % Pinned: a stub that is ported must update this count and README_MATLAB.
            tc.verifyEqual(stubs, 57, sprintf('%d stub files found', stubs));
        end
    end
end

function files = list_m(folder)
    files = {};
    entries = dir(folder);
    for k = 1:numel(entries)
        e = entries(k);
        if e.isdir && e.name(1) == '+'
            files = [files, list_m(fullfile(folder, e.name))]; %#ok<AGROW>
        elseif ~e.isdir && numel(e.name) > 2 && strcmp(e.name(end - 1:end), '.m')
            files{end + 1} = fullfile(folder, e.name); %#ok<AGROW>
        end
    end
end

function name = qualified_name(root, file)
    rel = strrep(file(numel(root) + 2:end - 2), '\', '/');
    parts = strsplit(rel, '/');
    parts = cellfun(@(p) strrep(p, '+', ''), parts, 'UniformOutput', false);
    name = strjoin(parts, '.');
end
