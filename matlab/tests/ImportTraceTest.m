classdef ImportTraceTest < matlab.unittest.TestCase
    % Parity: transport.import_trace vs Python's import_trace on 45 edge
    % cases and 80 seeded random trace files (make_fixtures.py:group_import_trace;
    % matlab/tools/trace_corpus.py runs the same comparison on thousands).
    % An error must have Python's message (panama_uav:trace; invalid UTF-8
    % is panama_uav:utf8). A success must write the same .npy bytes for
    % timestamps, delays, sequence and source_timestamps (sha256), the same
    % metadata JSON (the source path, which differs between machines,
    % replaced by @SOURCE@), and return the same metadata, floats bit for bit.
    methods (Test)
        function testImportMatchesPython(tc)
            fx = load_fixture('import_trace');
            cases = as_cell(fx.cases);
            tc.verifyEqual(numel(cases), 125);
            ok = 0;
            for k = 1:numel(cases)
                ok = ok + check_case(tc, cases{k}, sprintf('import case %d', k));
            end
            tc.verifyEqual(ok, 62);
        end
        function testOutputLoadsAsDelayTrace(tc)
            % The stored (not deflated) archive reads back through the same
            % .npz reader as NumPy's files, including NUL-padded '<U' arrays.
            folder = tempname();
            mkdir(folder);
            cleaner = onCleanup(@() rmdir(folder, 's'));
            source = fullfile(folder, 'owd.txt');
            write_bytes(source, uint8(sprintf('seq_nr ul_t0 owd_t0_t1\n7 1000 25\n10 2000 30\n')));
            m = panama_uav.transport.import_trace(source, fullfile(folder, 'sub', 'owd'), 'uplink', 'ms');
            t = panama_uav.transport.DelayTrace.load(fullfile(folder, 'sub', 'owd.npz'));
            tc.verifyEqual(t.timestamps, [0; 1]);
            tc.verifyEqual(t.delays, [0.025; 0.03]);
            tc.verifyEqual(t.metadata.rows, 2);
            tc.verifyEqual(m.column_names, {'seq_nr', 'ul_t0', 'owd_t0_t1'});
            data = panama_uav.util.read_npz(fullfile(folder, 'sub', 'owd.npz'), {'sequence'});
            tc.verifyEqual(data.sequence, {'7'; '10'});
            tc.verifyEqual(t.delay(0.5), 0.025);
        end
    end
end

function ok = check_case(tc, c, label)
    ok = 0;
    folder = tempname();
    mkdir(folder);
    cleaner = onCleanup(@() rmdir(folder, 's'));
    source = fullfile(folder, 'trace.txt');
    if isempty(c.hex)
        bytes = uint8([]);
    else
        bytes = uint8(hex2dec(reshape(c.hex, 2, [])'))';
    end
    write_bytes(source, bytes);
    args = {source, fullfile(folder, c.output), c.direction, c.unit, opt(c.start), opt(c.stop), opt(c.origin)};
    if isfield(c, 'error')
        id = 'panama_uav:trace';
        if strcmp(c.error_type, 'UnicodeDecodeError')
            id = 'panama_uav:utf8';
        end
        if any(double(c.error) > 127) && ~isempty(strfind(c.error, 'np.str_('))
            % Documented divergence: the port's repr escapes non-ASCII.
            tc.verifyError(@() panama_uav.transport.import_trace(args{:}), id, label);
            try
                panama_uav.transport.import_trace(args{:});
            catch err
                prefix = 'could not convert string to float: np.str_(';
                tc.verifyTrue(strncmp(err.message, prefix, numel(prefix)), [label, ' message']);
            end
        else
            verify_error_message(tc, @() panama_uav.transport.import_trace(args{:}), id, c.error, label);
        end
        return;
    end
    m = panama_uav.transport.import_trace(args{:});
    written = fullfile(folder, c.written);
    tc.verifyTrue(exist(written, 'file') == 2, [label, ' written as ', c.written]);
    unpacked = fullfile(folder, 'unpacked');
    mkdir(unpacked);
    unzip(written, unpacked);
    for name = {'timestamps', 'delays', 'sequence', 'source_timestamps'}
        tc.verifyEqual(panama_uav.records.sha256(fullfile(unpacked, [name{1}, '.npy'])), ...
            c.members_sha256.(name{1}), [label, ' ', name{1}, '.npy']);
    end
    crc = stored_crc32(written);
    for name = {'timestamps', 'delays', 'sequence', 'source_timestamps'}
        tc.verifyEqual(crc.(name{1}), c.members_crc32.(name{1}), [label, ' ', name{1}, '.npy CRC-32']);
    end
    data = panama_uav.util.read_npz(written, {'metadata'});
    quoted = ['"', m.source, '"'];
    want = panama_uav.util.decode_utf8(uint8(hex2dec(reshape(c.metadata_json_hex, 2, [])'))');
    tc.verifyEqual(strrep(data.metadata, quoted, '@SOURCE@'), want, [label, ' metadata json']);
    expected_source = canonical(source);
    tc.verifyEqual(m.source, expected_source, [label, ' source']);
    got = rmfield(m, 'source');
    check_tagged(tc, got, c.metadata, [label, ' metadata']);
    ok = 1;
end

function crc = stored_crc32(path)
% CRC-32 fields of the local headers of a STORED zip (write_npz), by name.
    fid = fopen(path, 'r');
    b = double(fread(fid, Inf, '*uint8')');
    fclose(fid);
    crc = struct();
    at = 1;
    le = @(i, n) sum(b(i:i + n - 1) .* 256 .^ (0:n - 1));
    while at + 30 <= numel(b) && le(at, 4) == 67324752
        n = le(at + 26, 2);
        size = le(at + 18, 4);
        name = char(b(at + 30:at + 29 + n));
        crc.(name(1:end - 4)) = le(at + 14, 4);
        at = at + 30 + n + size;
    end
end

function p = canonical(path)
    if panama_uav.util.is_octave()
        p = canonicalize_file_name(path);
    elseif usejava('jvm')
        p = char(java.io.File(path).getCanonicalPath());
    else
        p = path;
    end
end

function v = opt(x)
    if isempty(x)
        v = [];
    else
        v = panama_uav.util.hex_to_double(x);
    end
end

function write_bytes(path, bytes)
    fid = fopen(path, 'w');
    fwrite(fid, bytes, 'uint8');
    fclose(fid);
end
