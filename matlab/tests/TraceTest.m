classdef TraceTest < matlab.unittest.TestCase
    % Parity: DelayTrace.load (.npz reader) and DelayTrace.delay vs Python.
    methods (Test)
        function testLoadMatchesPython(tc)
            % The .npz files were written by Python's import_trace (see
            % make_fixtures.py:group_trace). Arrays are compared bit for bit
            % (tolerance 0: the reader copies float64 bytes, no arithmetic).
            fx = load_fixture('trace');
            for name = {'trace_uplink', 'trace_downlink'}
                want = fx.(name{1});
                t = panama_uav.transport.DelayTrace.load(trace_path(name{1}));
                tc.verifyEqual(bits(t.timestamps), bits(hexes(want.timestamps)), [name{1}, ' timestamps']);
                tc.verifyEqual(bits(t.delays), bits(hexes(want.delays)), [name{1}, ' delays']);
                check_tagged(tc, t.metadata, want.metadata, [name{1}, ' metadata']);
                % '<U' strings shorter than the array width are NUL-padded on disk.
                data = panama_uav.util.read_npz(trace_path(name{1}), {'sequence'});
                tc.verifyEqual(data.sequence, reshape(cellstr(want.sequence), [], 1), [name{1}, ' sequence']);
            end
        end
        function testDelayQueriesMatchPython(tc)
            % Step-function lookup at sample times, just before and after
            % them, outside the segment, at +-inf and NaN. Exact (the result
            % is a stored sample, selected by comparisons only).
            fx = load_fixture('trace');
            for name = {'trace_uplink', 'trace_downlink'}
                want = fx.(name{1});
                t = panama_uav.transport.DelayTrace.load(trace_path(name{1}));
                queries = as_cell(want.queries);
                tc.verifyEqual(numel(queries), 70);
                for k = 1:numel(queries)
                    q = queries{k};
                    time = panama_uav.util.hex_to_double(q.time);
                    label = sprintf('%s query %d', name{1}, k);
                    if isfield(q, 'error')
                        verify_error_message(tc, @() t.delay(time), 'panama_uav:trace', q.error, label);
                    else
                        tc.verifyEqual(bits(t.delay(time)), bits(panama_uav.util.hex_to_double(q.delay)), label);
                    end
                end
            end
        end
        function testReaderRejectsWhatNumPyRejects(tc)
            folder = tempname();
            mkdir(folder);
            cleaner = onCleanup(@() rmdir(folder, 's'));
            bad = fullfile(folder, 'bad.npy');
            fid = fopen(bad, 'w');
            fwrite(fid, uint8('not numpy'));
            fclose(fid);
            tc.verifyError(@() panama_uav.util.read_npy(bad), 'panama_uav:npy');
            tc.verifyError(@() panama_uav.util.read_npz(fullfile(folder, 'missing.npz'), {'a'}), 'panama_uav:npy');
            tc.verifyError(@() panama_uav.util.read_npz(trace_path('trace_uplink'), {'nope'}), 'panama_uav:npy');
            object_array = fullfile(folder, 'object.npy');
            write_npy_header(object_array, '|O', '(2,)', false, zeros(1, 2));
            verify_error_message(tc, @() panama_uav.util.read_npy(object_array), 'panama_uav:npy', ...
                'Object arrays cannot be loaded when allow_pickle=False', 'object array');   % NumPy's text
            % n-d arrays keep their shape in C and Fortran order.
            c_order = fullfile(folder, 'c.npy');
            write_npy_header(c_order, '<f8', '(2, 3)', false, 1:6);
            tc.verifyEqual(panama_uav.util.read_npy(c_order), [1 2 3; 4 5 6]);
            f_order = fullfile(folder, 'f.npy');
            write_npy_header(f_order, '<f8', '(2, 3)', true, 1:6);
            tc.verifyEqual(panama_uav.util.read_npy(f_order), [1 3 5; 2 4 6]);
            % Strings come back as N-by-1 cellstr with NULs stripped.
            data = panama_uav.util.read_npz(trace_path('trace_uplink'), {'sequence', 'source_timestamps'});
            tc.verifyTrue(iscellstr(data.sequence));
            tc.verifyEqual(data.source_timestamps{1}, '1700000000560000000');
        end
    end
end

function p = trace_path(name)
    p = fullfile(repo_root(), 'matlab', 'tests', 'fixtures', [name, '.npz']);
end

function x = hexes(c)
    x = reshape(panama_uav.util.hex_to_double(as_cell(c)), [], 1);
end

function b = bits(x)
    b = typecast(double(x(:)'), 'uint64');
end

function write_npy_header(path, descr, shape, fortran, values)
    % A version 1.0 .npy file as NumPy writes it (header padded to 64 bytes).
    orders = {'False', 'True'};
    header = sprintf('{''descr'': ''%s'', ''fortran_order'': %s, ''shape'': %s, }', descr, ...
        orders{fortran + 1}, shape);
    header = [header, repmat(' ', 1, 63 - mod(numel(header) + 10, 64)), sprintf('\n')];
    fid = fopen(path, 'w', 'ieee-le');
    fwrite(fid, uint8([147 double('NUMPY') 1 0]));
    fwrite(fid, numel(header), 'uint16');
    fwrite(fid, uint8(header));
    fwrite(fid, values, 'double');
    fclose(fid);
end
