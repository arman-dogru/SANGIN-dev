classdef EncodeTest < matlab.unittest.TestCase
    % Parity: encode_size vs len(transport.encode(value)) from Python.
    methods (Test)
        function testSizesMatchPython(tc)
            % Exact byte counts (tolerance 0: a size is an integer, and one
            % byte off changes every link-service time that depends on it).
            % 332 plain values: int/str/bytes length thresholds, frame
            % commits at 64 KiB, batches of 1000, and 250 seeded random
            % nested values. 221 mission-payload values (M1b-2): Guidance
            % instances, int-keyed and mixed-key dicts, int tuple rows
            % (also across a 64 KiB frame commit), 150 seeded random nested
            % ones and payloads captured from a physical-profile rollout.
            fx = load_fixture('encode');
            cases = as_cell(fx.cases);
            tc.verifyEqual(numel(cases), 553);
            tc.verifyEqual(sum(cellfun(@(c) isfield(c, 'mission'), cases)), 221);
            for k = 1:numel(cases)
                v = py_value(cases{k}.spec);
                tc.verifyEqual(panama_uav.transport.encode_size(v), cases{k}.size, ...
                    sprintf('case %d (%s)', k, cases{k}.spec.t));
            end
        end
        function testTupleRowsMatchPython(tc)
            % PyTupleRows sizes a list of int tuples without one object per
            % row; it must give Python's size wherever such a list occurs,
            % at the top level or nested, inside or across a frame commit.
            fx = load_fixture('encode');
            cases = as_cell(fx.cases);
            checked = 0;
            lists = 0;
            for k = 1:numel(cases)
                [v, n] = rows_as_matrix(cases{k}.spec);
                if n == 0
                    continue;
                end
                checked = checked + 1;
                lists = lists + n;
                tc.verifyEqual(panama_uav.transport.encode_size(v), cases{k}.size, ...
                    sprintf('rows case %d (%s)', k, cases{k}.spec.t));
            end
            tc.verifyEqual([checked, lists], [124, 243]);   % cases, tuple-row lists in them
        end
        function testTupleRowsMatchCellLists(tc)
            % Shapes the fixtures never put in a tuple_rows spec (0 or 1
            % rows, 0 to 4 items, batch edges at 1000, int widths, lists
            % crossing several frame commits from varying offsets): the size
            % must equal the one of the same list as a cell row of PyTuple,
            % which testSizesMatchPython pins to Python.
            widths = [0, 255, 256, 65535, 65536, 2147483647, 2147483648, -1, -2147483648, -2147483649];
            checked = 0;
            for n = [0, 1, 2, 3, 999, 1000, 1001, 2000]
                for k = 0:4
                    m = int64(widths(1 + mod((1:n)' * 7 + (1:k) * 3, numel(widths))));
                    m = reshape(m, n, k);
                    check_rows(tc, m, '', sprintf('%d x %d', n, k));
                    checked = checked + 1;
                end
            end
            for pad = [0, 7, 65530, 65536, 70000]
                for n = [6000, 12000]
                    m = int64(mod((1:n)' * [7919, 104729], 70001));
                    check_rows(tc, m, repmat('a', 1, pad), sprintf('%d rows after %d bytes', n, pad));
                    checked = checked + 1;
                end
            end
            tc.verifyEqual(checked, 50);
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
            tc.verifyEqual(checked, 29);
        end
        function testUnmappedTypesRaise(tc)
            % No guessed Python type: numeric arrays (tuple, list or NumPy
            % array?), struct arrays and column cells are refused; mission
            % payloads are mapped by information.mission_wire instead.
            tc.verifyError(@() panama_uav.transport.encode_size([1 2]), 'panama_uav:notImplemented');
            tc.verifyError(@() panama_uav.transport.encode_size(struct('a', {1, 2})), 'panama_uav:notImplemented');
            tc.verifyError(@() panama_uav.transport.encode_size({1; 2}), 'panama_uav:notImplemented');
            tc.verifyError(@() panama_uav.transport.encode_size(struct('p', [3 4])), 'panama_uav:notImplemented');
            tc.verifyError(@() panama_uav.transport.PyBytes(-1), 'panama_uav:encode');
            tc.verifyError(@() panama_uav.transport.PyTupleRows([1.5 2]), 'panama_uav:encode');
            tc.verifyError(@() panama_uav.transport.PyTupleRows([inf 2]), 'panama_uav:encode');
            tc.verifyError(@() panama_uav.transport.PyDict({1}, {}), 'panama_uav:encode');
            tc.verifyError(@() panama_uav.transport.PyInstance('', 'Guidance', struct()), 'panama_uav:encode');
            tc.verifyError(@() panama_uav.information.mission_wire('model', struct()), 'panama_uav:encode');
        end
    end
end

function [v, n] = rows_as_matrix(spec)
% SPEC with every tuple_rows replaced by PyTupleRows; N counts them.
    n = 0;
    switch spec.t
        case 'tuple_rows'
            v = panama_uav.transport.PyTupleRows(tuple_rows_matrix(spec));
            n = 1;
        case {'list', 'tuple'}
            items = as_cell(spec.items);
            vals = cell(1, numel(items));
            for k = 1:numel(items)
                [vals{k}, m] = rows_as_matrix(items{k});
                n = n + m;
            end
            if strcmp(spec.t, 'tuple')
                v = panama_uav.transport.PyTuple(vals{:});
            elseif isempty(vals)
                v = {};
            else
                v = vals;
            end
        case 'dict'
            keys = as_cell(spec.keys);
            values = as_cell(spec.values);
            ks = cell(1, numel(keys));
            vs = cell(1, numel(keys));
            for k = 1:numel(keys)
                [ks{k}, a] = rows_as_matrix(keys{k});
                [vs{k}, b] = rows_as_matrix(values{k});
                n = n + a + b;
            end
            v = panama_uav.transport.PyDict(ks, vs);
        case 'object'
            [state, n] = rows_as_matrix(spec.state);
            v = panama_uav.transport.PyInstance(spec.module, spec.qualname, state);
        otherwise
            v = py_value(spec);
    end
end

function check_rows(tc, m, pad, label)
% Size of [pad, rows, pad] with the rows as PyTupleRows and as PyTuple cells.
    cells = cell(1, size(m, 1));
    for r = 1:size(m, 1)
        items = num2cell(m(r, :));
        cells{r} = panama_uav.transport.PyTuple(items{:});
    end
    want = panama_uav.transport.encode_size({pad, cells, pad});
    got = panama_uav.transport.encode_size({pad, panama_uav.transport.PyTupleRows(m), pad});
    tc.verifyEqual(got, want, label);
end
