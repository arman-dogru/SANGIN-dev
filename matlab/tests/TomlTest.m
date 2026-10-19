classdef TomlTest < matlab.unittest.TestCase
    % Parity: panama_uav.util.toml_decode vs Python tomllib on configs/*.toml.
    methods (Test)
        function testAllConfigsMatchTomllib(tc)
            fx = load_fixture('toml');
            cases = as_cell(fx.cases);
            tc.verifyEqual(numel(cases), 4);   % base, fast_pilot, leo_learning, leo_tremblant
            for k = 1:numel(cases)
                text = panama_uav.util.read_text(fullfile(repo_root(), cases{k}.file));
                got = panama_uav.util.canonical(panama_uav.util.toml_decode(text));
                tc.verifyEqual(got, cases{k}.canonical, cases{k}.file);
            end
        end
        function testScalarsAndErrors(tc)
            d = panama_uav.util.toml_decode(sprintf(['a = 1_000\nb = -2.5e3\nc = "x\\ty" # c\n', ...
                'd = [1, 2,\n 3,]\ne = {f = true}\n[t.u]\nv = ''lit''\n[[s]]\nn = 1\n[[s]]\nn = 0x1f\n']));
            tc.verifyEqual(d.a, int64(1000));
            tc.verifyEqual(d.b, -2500);
            tc.verifyEqual(d.c, sprintf('x\ty'));
            tc.verifyEqual(d.d, {int64(1), int64(2), int64(3)});
            tc.verifyEqual(d.e.f, true);
            tc.verifyEqual(d.t.u.v, 'lit');
            tc.verifyEqual(d.s{2}.n, int64(31));
            tc.verifyError(@() panama_uav.util.toml_decode('a = '), 'panama_uav:toml');
            tc.verifyError(@() panama_uav.util.toml_decode('a = 1 2'), 'panama_uav:toml');
        end
        function testTextsMatchTomllib(tc)
            % Number grammar, duplicate keys/tables and end-of-input wording,
            % each text recorded from tomllib (make_fixtures.py TOML_TEXTS):
            % accepted texts decode to the same canonical value; rejected
            % ones raise panama_uav:toml at tomllib's location.
            fx = load_fixture('toml');
            texts = as_cell(fx.texts);
            tc.verifyEqual(numel(texts), 66);
            for k = 1:numel(texts)
                t = texts{k};
                label = sprintf('%s', strrep(t.text, char(10), '\n'));
                if t.accepted
                    got = 'error';
                    try
                        got = panama_uav.util.canonical(panama_uav.util.toml_decode(t.text));
                    catch err
                        got = ['error: ', err.message];
                    end
                    tc.verifyEqual(got, t.canonical, label);
                else
                    msg = '';
                    id = '';
                    try
                        panama_uav.util.toml_decode(t.text);
                    catch err
                        msg = err.message;
                        id = err.identifier;
                    end
                    tc.verifyEqual(id, 'panama_uav:toml', label);
                    if strcmp(t.location, 'end of document')
                        want = 'at end of document:';
                    else
                        want = ['on ', t.location, ':'];
                    end
                    tc.verifyTrue(~isempty(strfind(msg, want)), sprintf('%s: want "%s", got "%s"', label, want, msg));
                end
            end
        end
        function testExponentOnlyFloats(tc)
            % Floats with an exponent and no '.' (TOML allows 1e5) stay double.
            d = panama_uav.util.toml_decode(sprintf('a = 1e5\nb = -2E-3\nc = 3e+2\nd = 5\n'));
            tc.verifyEqual(d.a, 1e5);
            tc.verifyEqual(d.b, -2e-3);
            tc.verifyEqual(d.c, 300);
            tc.verifyEqual(d.d, int64(5));
        end
        function testErrorLineMatchesTomllib(tc)
            % Expected lines are tomllib's (Python 3.13) for the same texts.
            cases = { ...
                sprintf('[training\n'),             'line 1:'; ...
                sprintf('a = 1\n[training\n\n'),    'line 2:'; ...
                sprintf('a = 1\nb = \n'),           'line 2:'; ...
                sprintf('a = 1\nb = 2\nc = @\n'),   'line 3:'; ...
                'a = 1 2',                          'line 1:'; ...
                sprintf('a = "x\n'),               'line 1:'; ...
                sprintf('k = [1,\n2\n'),           'at end of document:'};
            for k = 1:size(cases, 1)
                msg = '';
                id = '';
                try
                    panama_uav.util.toml_decode(cases{k, 1});
                catch err
                    msg = err.message;
                    id = err.identifier;
                end
                tc.verifyEqual(id, 'panama_uav:toml', sprintf('case %d', k));
                tc.verifyTrue(~isempty(strfind(msg, cases{k, 2})), sprintf('case %d: %s', k, msg));
            end
        end
    end
end
