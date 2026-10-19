classdef ScaffoldTest < matlab.unittest.TestCase
    % Every not-yet-ported entry point fails loudly with panama_uav:notImplemented.
    methods (Test)
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
            tc.verifyTrue(stubs >= 50, sprintf('only %d stubs found', stubs));
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
