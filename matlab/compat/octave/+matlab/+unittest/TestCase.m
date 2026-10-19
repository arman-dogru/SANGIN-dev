classdef TestCase < handle
    %TESTCASE Minimal matlab.unittest.TestCase shim for GNU Octave.
    %   Only on the path under Octave (see matlab/run_tests.m). Implements the
    %   qualification methods used by matlab/tests. Verifications record a
    %   failure and continue; assertions throw. Supports 'AbsTol'/'RelTol'.
    properties
        Failures = {}
    end
    methods
        function verifyEqual(tc, actual, expected, varargin)
            [ok, why] = tc.compare(actual, expected, varargin{:});
            if ~ok, tc.fail(['verifyEqual: ', why], varargin{:}); end
        end
        function assertEqual(tc, actual, expected, varargin)
            [ok, why] = tc.compare(actual, expected, varargin{:});
            if ~ok, error('shim:assert', 'assertEqual: %s', why); end
        end
        function verifyTrue(tc, x, varargin)
            if ~(islogical(x) || isnumeric(x)) || ~all(x(:)), tc.fail('verifyTrue', varargin{:}); end
        end
        function verifyFalse(tc, x, varargin)
            if any(x(:)), tc.fail('verifyFalse', varargin{:}); end
        end
        function verifyEmpty(tc, x, varargin)
            if ~isempty(x), tc.fail('verifyEmpty', varargin{:}); end
        end
        function verifyLessThanOrEqual(tc, a, b, varargin)
            if ~all(a(:) <= b(:)), tc.fail(sprintf('verifyLessThanOrEqual: %g > %g', max(a(:)), b), varargin{:}); end
        end
        function verifyError(tc, f, id, varargin)
            try
                f();
                tc.fail(['verifyError: no error, expected ', id], varargin{:});
            catch err
                if ~strcmp(err.identifier, id)
                    tc.fail(sprintf('verifyError: got "%s" (%s), expected %s', ...
                        err.identifier, err.message, id), varargin{:});
                end
            end
        end
    end
    methods (Access = private)
        function fail(tc, msg, varargin)
            extra = '';
            for k = 1:numel(varargin)
                if ischar(varargin{k}) && ~any(strcmp(varargin{k}, {'AbsTol', 'RelTol'})) ...
                        && (k == 1 || ~any(strcmp(varargin{k - 1}, {'AbsTol', 'RelTol'})))
                    extra = [' (', varargin{k}, ')'];
                end
            end
            tc.Failures{end + 1} = [msg, extra];
        end
        function [ok, why] = compare(~, a, e, varargin)
            abstol = 0;
            reltol = 0;
            for k = 1:numel(varargin) - 1
                if ischar(varargin{k}) && strcmp(varargin{k}, 'AbsTol'), abstol = varargin{k + 1}; end
                if ischar(varargin{k}) && strcmp(varargin{k}, 'RelTol'), reltol = varargin{k + 1}; end
            end
            why = '';
            if abstol == 0 && reltol == 0
                ok = isequal(a, e);
                if ~ok && isnumeric(a) && isnumeric(e)
                    ok = isequal(class(a), class(e)) && isequal(size(a), size(e)) && isequaln(a, e);
                end
                if ~ok
                    why = sprintf('values differ (%s %s vs %s %s)', class(a), mat2str(size(a)), ...
                        class(e), mat2str(size(e)));
                end
                return;
            end
            if ~isequal(size(a), size(e))
                ok = false;
                why = sprintf('size %s vs %s', mat2str(size(a)), mat2str(size(e)));
                return;
            end
            a = double(a);
            e = double(e);
            same = (a == e) | (isnan(a) & isnan(e));
            within = abs(a - e) <= max(abstol, reltol * abs(e));
            ok = all(same(:) | within(:));
            if ~ok
                why = sprintf('max abs diff %g', max(abs(a(:) - e(:))));
            end
        end
    end
end
