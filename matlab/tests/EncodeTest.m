classdef EncodeTest < matlab.unittest.TestCase
    % Parity: encode_size vs len(transport.encode(value)) from Python.
    methods (Test)
        function testSizesMatchPython(tc)
            % Exact byte counts (tolerance 0: a size is an integer, and one
            % byte off changes every link-service time that depends on it).
            % 332 values: int/str/bytes length thresholds, frame commits at
            % 64 KiB, batches of 1000, and 250 seeded random nested values.
            fx = load_fixture('encode');
            cases = as_cell(fx.cases);
            tc.verifyEqual(numel(cases), 332);
            for k = 1:numel(cases)
                v = py_value(cases{k}.spec);
                tc.verifyEqual(panama_uav.transport.encode_size(v), cases{k}.size, ...
                    sprintf('case %d (%s)', k, cases{k}.spec.t));
            end
        end
        function testUnsignedIntsMatchPython(tc)
            % A uint64 stands for the same Python int as an int64 of equal
            % value: every nonnegative fixture int below 2**63 must give the
            % same size as uint64, including 2**31 - 1 / 2**31 (BININT vs LONG1).
            fx = load_fixture('encode');
            cases = as_cell(fx.cases);
            checked = 0;
            for k = 1:numel(cases)
                spec = cases{k}.spec;
                if ~strcmp(spec.t, 'int') || spec.unsigned
                    continue;
                end
                v = py_value(spec);
                if v < 0
                    continue;
                end
                checked = checked + 1;
                tc.verifyEqual(panama_uav.transport.encode_size(uint64(v)), cases{k}.size, ...
                    sprintf('uint64 case %d (%s)', k, spec.v));
            end
            tc.verifyTrue(checked > 10, sprintf('only %d nonnegative int cases', checked));
        end
        function testUnmappedTypesRaise(tc)
            % No guessed Python type: numeric arrays (tuple, list or NumPy
            % array?), struct arrays and column cells are refused (the
            % mission payloads are M1b-2).
            tc.verifyError(@() panama_uav.transport.encode_size([1 2]), 'panama_uav:notImplemented');
            tc.verifyError(@() panama_uav.transport.encode_size(struct('a', {1, 2})), 'panama_uav:notImplemented');
            tc.verifyError(@() panama_uav.transport.encode_size({1; 2}), 'panama_uav:notImplemented');
            tc.verifyError(@() panama_uav.transport.encode_size(struct('p', [3 4])), 'panama_uav:notImplemented');
            tc.verifyError(@() panama_uav.transport.PyBytes(-1), 'panama_uav:encode');
        end
    end
end
