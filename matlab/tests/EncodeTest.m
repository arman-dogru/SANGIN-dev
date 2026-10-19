classdef EncodeTest < matlab.unittest.TestCase
    % Parity: encode_size vs len(transport.encode(value)) from Python.
    methods (Test)
        function testSizesMatchPython(tc)
            % Exact byte counts (tolerance 0: a size is an integer, and one
            % byte off changes every link-service time that depends on it).
            % 331 values: int/str/bytes length thresholds, frame commits at
            % 64 KiB, batches of 1000, and 250 seeded random nested values.
            fx = load_fixture('encode');
            cases = as_cell(fx.cases);
            tc.verifyEqual(numel(cases), 331);
            for k = 1:numel(cases)
                v = py_value(cases{k}.spec);
                tc.verifyEqual(panama_uav.transport.encode_size(v), cases{k}.size, ...
                    sprintf('case %d (%s)', k, cases{k}.spec.t));
            end
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
