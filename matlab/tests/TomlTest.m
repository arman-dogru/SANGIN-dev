classdef TomlTest < matlab.unittest.TestCase
    % Parity: panama_uav.util.toml_decode vs Python tomllib on configs/*.toml.
    methods (Test)
        function testAllConfigsMatchTomllib(tc)
            fx = load_fixture('toml');
            cases = as_cell(fx.cases);
            tc.verifyEqual(numel(cases), 13);
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
    end
end
