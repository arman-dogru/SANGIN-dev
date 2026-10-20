function ok = run_tests(pattern)
%RUN_TESTS Run the MATLAB port's parity and unit tests on MATLAB or Octave.
%   ok = run_tests()            % all tests in matlab/tests
%   ok = run_tests('Env')       % only test files whose name contains 'Env'
%   ok = run_tests('EnvironmentParityTest/testPhysical')   % methods by prefix
%
%   MATLAB (R2021b+): uses matlab.unittest (runtests) and needs no toolbox.
%   GNU Octave (9.x): adds compat/octave, which provides a small
%   matlab.unittest.TestCase shim, then runs every method whose name starts
%   with 'test' in tests/*Test.m. Returns true when all tests pass, and
%   false when the selection matches no test (so a mistyped pattern fails
%   a CI job instead of passing it).
    if nargin < 1
        pattern = '';
    end
    here = fileparts(mfilename('fullpath'));
    addpath(here);
    addpath(fullfile(here, 'tests'));
    files = dir(fullfile(here, 'tests', '*Test.m'));
    names = sort(cellfun(@(n) n(1:end - 2), {files.name}, 'UniformOutput', false));
    selection = pattern;
    method = '';
    slash = strfind(pattern, '/');
    if ~isempty(slash)
        method = pattern(slash(1) + 1:end);
        pattern = pattern(1:slash(1) - 1);
    end
    if ~isempty(pattern)
        names = names(~cellfun(@isempty, strfind(names, pattern)));
    end
    if ~panama_uav.util.is_octave()
        suite = matlab.unittest.TestSuite.fromFolder(fullfile(here, 'tests'));
        if ~isempty(method)
            suite = suite.selectIf('Name', ['*', pattern, '*/', method, '*']);
        elseif ~isempty(pattern)
            suite = suite.selectIf('Name', ['*', pattern, '*']);
        end
        if isempty(suite)
            fprintf('No test matches ''%s''\n', selection);
            ok = false;
            return;
        end
        results = run(suite);
        disp(table(results));
        ok = all([results.Passed]);
        return;
    end
    addpath(fullfile(here, 'compat', 'octave'));
    passed = 0;
    failed = {};
    for f = 1:numel(names)
        methods_list = methods(names{f});
        tests = sort(methods_list(strncmp(methods_list, 'test', 4)));
        if ~isempty(method)
            tests = tests(strncmp(tests, method, numel(method)));
        end
        for m = 1:numel(tests)
            label = [names{f}, '/', tests{m}];
            t0 = tic;
            try
                tc = feval(names{f});
                tc.(tests{m})();
                if isempty(tc.Failures)
                    passed = passed + 1;
                    fprintf('  PASS %-60s %6.2fs\n', label, toc(t0));
                else
                    failed{end + 1} = label; %#ok<AGROW>
                    fprintf('  FAIL %-60s\n', label);
                    fprintf('       %s\n', tc.Failures{1:min(5, end)});
                end
            catch err
                failed{end + 1} = label; %#ok<AGROW>
                fprintf('  ERROR %-59s\n       %s: %s\n', label, err.identifier, err.message);
                if ~isempty(err.stack)
                    fprintf('       at %s line %d\n', err.stack(1).name, err.stack(1).line);
                end
            end
        end
    end
    if passed + numel(failed) == 0
        fprintf('No test matches ''%s''\n', selection);
        ok = false;
        return;
    end
    fprintf('\n%d passed, %d failed\n', passed, numel(failed));
    ok = isempty(failed);
end
