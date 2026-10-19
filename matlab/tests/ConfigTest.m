classdef ConfigTest < matlab.unittest.TestCase
    % Parity: panama_uav.config.load_config vs Python config.load_config.
    methods (Test)
        function testBaseConfigMatchesPython(tc)
            fx = load_fixture('config');
            c = panama_uav.config.load_config(fullfile(repo_root(), 'configs', 'base.toml'));
            tc.verifyEqual(normalize(rmfield(c, 'project_root')), normalize(fx.base));
            tc.verifyEqual(panama_uav.config.vector_length(c), fx.vector_length);
            smoke = panama_uav.config.profile(c, 'smoke');
            tc.verifyEqual(normalize(smoke.training), normalize(fx.smoke_training));
        end
        function testAcceptAndRejectLikePython(tc)
            fx = load_fixture('config');
            files = as_cell(fx.files);
            for k = 1:numel(files)
                path = fullfile(repo_root(), files{k}.file);
                if files{k}.accepted
                    c = panama_uav.config.load_config(path);
                    tc.verifyEqual(normalize(rmfield(c, 'project_root')), normalize(files{k}.config), files{k}.file);
                else
                    tc.verifyError(@() panama_uav.config.load_config(path), 'panama_uav:config', files{k}.file);
                end
            end
        end
        function testSyntheticAcceptAndRejectLikePython(tc)
            % configs/ only holds accepted files, so the rejection rules
            % (legacy sections, unknown keys, bad transport, wrong ladder)
            % are pinned with small TOML texts run through Python too.
            fx = load_fixture('config');
            cases = as_cell(fx.synthetic);
            tc.verifyEqual(numel(cases), 7);
            root = tempname();
            mkdir(fullfile(root, 'configs'));
            cleanup = onCleanup(@() rmdir(root, 's')); %#ok<NASGU>
            for k = 1:numel(cases)
                path = fullfile(root, 'configs', [cases{k}.name '.toml']);
                fid = fopen(path, 'w');
                fwrite(fid, cases{k}.text, 'char');
                fclose(fid);
                if cases{k}.accepted
                    c = panama_uav.config.load_config(path);
                    tc.verifyEqual(normalize(rmfield(c, 'project_root')), normalize(cases{k}.config), cases{k}.name);
                else
                    tc.verifyError(@() panama_uav.config.load_config(path), 'panama_uav:config', cases{k}.name);
                end
            end
        end
        function testTransportValidation(tc)
            c = panama_uav.config.load_config(fullfile(repo_root(), 'configs', 'base.toml'));
            tc.verifyError(@() panama_uav.config.with_communication(c, 'profile', 'bogus'), 'panama_uav:config');
            tc.verifyError(@() panama_uav.config.with_communication(c, 'windows_max', 3), 'panama_uav:config');
            tc.verifyError(@() panama_uav.config.with_communication(c, 'stale_information', {'x'}), 'panama_uav:config');
        end
    end
end

function v = normalize(v)
% Round-trip through JSON so MATLAB and Python containers compare equal.
    v = sortfields(jsondecode(jsonencode(v)));
end

function v = sortfields(v)
    if isstruct(v)
        v = orderfields(v);
        names = fieldnames(v);
        for i = 1:numel(v)
            for k = 1:numel(names)
                v(i).(names{k}) = sortfields(v(i).(names{k}));
            end
        end
    elseif iscell(v)
        v = cellfun(@sortfields, v, 'UniformOutput', false);
    end
end
