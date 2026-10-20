function metadata = import_trace(source, output, direction, unit, start_s, end_s, origin_seconds)
%IMPORT_TRACE Import a three-column SATPIPE/Starlink one-way-delay trace
%   (src/panama_uav/transport.py:import_trace).
%
%   METADATA = panama_uav.transport.import_trace(SOURCE, OUTPUT, DIRECTION,
%   UNIT, START_S, END_S, ORIGIN_SECONDS) reads SOURCE (sequence number,
%   transmit timestamp, one-way delay per row), keeps the rows whose
%   timestamp is in [START_S, END_S] (in seconds after scaling; [] for no
%   bound), shifts timestamps by ORIGIN_SECONDS (default: the first kept
%   timestamp) and writes OUTPUT as an .npz with the arrays timestamps,
%   delays, sequence, source_timestamps and metadata (JSON), which
%   DelayTrace.load and Python's DelayTrace.load read. DIRECTION is
%   'uplink' or 'downlink'; UNIT is 'ns' (default), 'us', 'ms' or 's'.
%   Sequence gaps are not treated as loss. METADATA is the struct Python
%   returns (column_names is [] for None). Errors are panama_uav:trace with
%   Python's messages; invalid UTF-8 is panama_uav:utf8.
%
%   Parsing follows np.loadtxt(SOURCE, dtype=str, delimiter=..., ndmin=2)
%   of NumPy 2.x as Python calls it:
%   - the delimiter is ',' when the first line of the text contains a
%     comma (lines as str.splitlines cuts them, which also breaks at \v,
%     \f, \x1c-\x1e, \x85, U+2028 and U+2029), whitespace otherwise; an
%     empty file has no first line (Python: IndexError);
%   - rows end at \n, \r\n or \r; '#' starts a comment to the end of the
%     row; there is no quoting;
%   - whitespace mode splits at runs of str.isspace characters and skips
%     rows with no field; comma mode splits at every ',', keeps the spaces
%     in each field and skips only rows that are empty after the comment
%     is cut;
%   - all rows must have as many fields as the first ("the number of
%     columns changed from A to B at row R; ..."); with no rows the shape
%     is (0, 1), which fails the three-column check;
%   - a str array is as wide as its longest field anywhere in the file
%     (the header row and the delay column included), and NumPy drops
%     trailing NUL characters when a field is read back.
%   Timestamps are converted with Python's float() and delays with NumPy's
%   astype(float), which agree once trailing NULs are gone: optional
%   whitespace (ASCII, and non-ASCII str.isspace characters), a sign, digits
%   with single underscores between them (any Unicode decimal digit, as
%   Python accepts), an optional fraction and exponent, or inf, infinity and
%   nan in any case. Then values are scaled by the unit (one IEEE
%   multiplication, as NumPy does).
%
%   Divergences (documented in matlab/PORT_PLAN.md): the .npz entries are
%   stored rather than deflated (panama_uav.util.write_npz), so the archive
%   bytes differ while each .npy member is byte-identical; on MATLAB
%   without a JVM, metadata.source is the absolute path without resolving
%   symbolic links (Python: Path.resolve()); a value that fails to convert
%   is reported with a repr that escapes every non-ASCII character
%   (Python leaves printable ones as they are).
    if nargin < 4 || isempty(unit)
        unit = 'ns';
    end
    if nargin < 5
        start_s = [];
    end
    if nargin < 6
        end_s = [];
    end
    if nargin < 7
        origin_seconds = [];
    end
    if ~any(strcmp(direction, {'uplink', 'downlink'}))
        error('panama_uav:trace', 'Direction is required');
    end
    units = {'ns', 'us', 'ms', 's'};
    scales = [1e-9, 1e-6, 1e-3, 1.0];
    u = find(strcmp(unit, units), 1);
    if isempty(u)
        error('panama_uav:trace', 'Explicit supported units required');
    end
    scale = scales(u);

    % Python's source.read_text(): IsADirectoryError for a directory (as on
    % Linux and macOS; Windows raises PermissionError, Errno 13), else
    % FileNotFoundError when it cannot be opened.
    if exist(source, 'dir') == 7
        error('panama_uav:trace', '[Errno 21] Is a directory: ''%s''', source);
    end
    fid = fopen(source, 'r');
    if fid < 0
        error('panama_uav:trace', '[Errno 2] No such file or directory: ''%s''', source);
    end
    bytes = fread(fid, Inf, '*uint8')';
    fclose(fid);
    panama_uav.util.decode_utf8(bytes);                       % Python's UnicodeDecodeError
    text = panama_uav.util.utf8_codepoints(bytes);

    raw = loadtxt_str(text);                                  % cell, rows x columns, NULs kept
    if size(raw, 2) ~= 3
        error('panama_uav:trace', 'Expected sequence, transmit timestamp, one-way delay');
    end
    width = max([1, reshape(cellfun('length', raw), 1, [])]);
    if any(text == 0)
        value = cellfun(@strip_nul, raw, 'UniformOutput', false);
    else
        value = raw;                                          % no NUL to drop
    end
    column_names = [];
    if size(value, 1) >= 1 && is_text(value{1, 1}, 'seq_nr') ...
            && (is_text(value{1, 2}, 'ul_t0') || is_text(value{1, 2}, 'dl_t0')) ...
            && is_text(value{1, 3}, 'owd_t0_t1')
        column_names = cellfun(@char, value(1, :), 'UniformOutput', false);
        raw = raw(2:end, :);
        value = value(2:end, :);
    end
    if isempty(value)
        error('panama_uav:trace', 'Empty trace file');
    end
    n = size(value, 1);
    timestamps = py_floats(value(:, 2)) * scale;
    delays = py_floats(value(:, 3)) * scale;
    if ~all(isfinite(timestamps)) || ~all(isfinite(delays)) || any(delays < 0)
        error('panama_uav:trace', 'Invalid trace values');
    end
    if any(diff(timestamps) < 0)
        error('panama_uav:trace', 'Trace timestamps must be ordered');
    end
    mask = true(n, 1);
    if ~isempty(start_s)
        mask = mask & timestamps >= start_s;
    end
    if ~isempty(end_s)
        mask = mask & timestamps <= end_s;
    end
    if ~any(mask)
        error('panama_uav:trace', 'Empty trace segment');
    end
    chosen = timestamps(mask);
    if isempty(origin_seconds)
        origin = chosen(1);
    else
        origin = double(origin_seconds);
    end
    if origin > chosen(1)
        error('panama_uav:trace', 'Trace origin must not be later than its first sample');
    end
    kept = value(mask, :);
    source_path = resolved(source);
    metadata = struct( ...
        'source', source_path, ...
        'source_sha256', panama_uav.util.sha256_bytes(bytes), ...
        'direction', direction, ...
        'source_unit', unit, ...
        'stored_unit', 'seconds', ...
        'source_first_timestamp', panama_uav.util.codepoints_char(kept{1, 2}), ...
        'source_last_timestamp', panama_uav.util.codepoints_char(kept{end, 2}), ...
        'segment_start_seconds', origin, ...
        'segment_end_seconds', chosen(end), ...
        'rows', sum(mask), ...
        'column_names', {column_names}, ...
        'time_origin_seconds', origin, ...
        'missing_sequences_are_loss', false, ...
        'replacement_scope', 'entire satellite backhaul hop; access remains modeled', ...
        'handover_identification', 'not inferred from delay spikes');
    json = metadata_json(metadata, kept{1, 2}, kept{end, 2}, panama_uav.util.char_codepoints(source_path));

    out = output;
    if numel(out) < 4 || ~strcmp(out(end - 3:end), '.npz')
        out = [out, '.npz'];                                  % np.savez appends .npz
    end
    folder = fileparts(out);
    if ~isempty(folder) && ~exist(folder, 'dir')
        mkdir(folder);
    end
    raw_kept = raw(mask, :);
    members = { ...
        panama_uav.util.npy_bytes('f8', chosen - origin), ...
        panama_uav.util.npy_bytes('f8', delays(mask)), ...
        panama_uav.util.npy_bytes('U', raw_kept(:, 1)', width), ...
        panama_uav.util.npy_bytes('U', raw_kept(:, 2)', width), ...
        panama_uav.util.npy_bytes('U', json)};
    panama_uav.util.write_npz(out, {'timestamps', 'delays', 'sequence', 'source_timestamps', 'metadata'}, members);
end

function raw = loadtxt_str(text)
% np.loadtxt(dtype=str, delimiter=',' or None, ndmin=2) on code points TEXT.
% Vectorised over the whole text: rows, comments and fields are found with
% masks and cumulative sums, and the fields cut out with one mat2cell.
    if isempty(text)
        error('panama_uav:trace', 'list index out of range');   % Python: IndexError
    end
    breaks = [10 13 11 12 28 29 30 133 8232 8233];             % str.splitlines boundaries
    first = text(1:find([ismember(text, breaks), true], 1) - 1);
    comma = any(first == 44);
    % Rows end at \n, \r\n or \r: every \r ends one, a \n ends one unless
    % it follows a \r.
    text = [reshape(text, 1, []), 10];
    cr = text == 13;
    lf = text == 10;
    ends = find(cr | (lf & ~[false, cr(1:end - 1)]));
    nlines = numel(ends);
    starts = [1, ends(1:end - 1) + 1];
    line = zeros(1, numel(text));
    line(starts) = 1;
    line = cumsum(line);                                     % row (line) index of each code point
    % '#' starts a comment to the end of the row.
    hashes = cumsum(text == 35);
    before = [0, hashes(starts(2:end) - 1)];
    content = ~(cr | lf) & (hashes - before(line)) == 0;
    if comma
        % Skip rows that are empty once the comment is cut; split the others
        % at every ','.
        used = accumarray(line(content)', 1, [nlines, 1])' > 0;
        sep = content & text == 44;
        event = zeros(1, numel(text));
        event(starts(used)) = 1;
        event = event + sep;
        field = cumsum(event);
        keep = content & ~sep;
        count = accumarray(line(sep)', 1, [nlines, 1])' + 1;
        count = count(used);
        lengths = accumarray(field(keep)', 1, [sum(event), 1])';
    else
        % Split at runs of whitespace; rows with no field are skipped.
        keep = content & ~is_space(text);
        open_ = keep & ~[false, keep(1:end - 1)];
        close_ = keep & ~[keep(2:end), false];
        lengths = find(close_) - find(open_) + 1;
        count = accumarray(line(open_)', 1, [nlines, 1])';
        count = count(count > 0);
    end
    if isempty(count)
        raw = cell(0, 1);
        return;
    end
    columns = count(1);
    r = find(count ~= columns, 1);
    if ~isempty(r)
        error('panama_uav:trace', ['the number of columns changed from %d to %d at row %d; ', ...
            'use `usecols` to select a subset and avoid this error'], columns, count(r), r);
    end
    cells = mat2cell(text(keep), 1, lengths);
    for j = find(lengths == 0)
        cells{j} = zeros(1, 0);
    end
    raw = reshape(cells, columns, numel(count))';
end

function tf = is_space(cp)
% str.isspace without the row breaks \n and \r.
    tf = (cp >= 9 & cp <= 12) | (cp >= 28 & cp <= 32) | cp == 133 | cp == 160 | cp == 5760 ...
        | (cp >= 8192 & cp <= 8202) | cp == 8232 | cp == 8233 | cp == 8239 | cp == 8287 | cp == 12288;
end

function v = strip_nul(cp)
    k = find(cp ~= 0, 1, 'last');
    if isempty(k)
        v = zeros(1, 0);
    else
        v = cp(1:k);
    end
end

function tf = is_text(cp, s)
    tf = isequal(cp, double(s));
end

function x = py_floats(cells)
% py_float of every cell, in order (so the first bad value is the one
% reported). Plain ASCII decimals ([+-]digits[.digits][e[+-]digits], with
% no whitespace or underscores) are converted together with one
% str2double, the same conversion py_float applies to them; any other
% value goes through py_float on its own.
    n = numel(cells);
    x = zeros(n, 1);
    if n == 0
        return;
    end
    lengths = reshape(cellfun('length', cells), 1, []);
    flat = reshape([cells{:}], 1, []);
    if any(flat > 127)
        plain = false(n, 1);
    else
        strs = mat2cell(char(flat), 1, lengths);
        plain = ~cellfun('isempty', regexp(strs, ...
            '^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$', 'once'));
        plain = reshape(plain, [], 1);
    end
    if any(plain)
        p = reshape(strs(plain), [], 1);
        negative = strncmp(p, '-', 1);
        x(plain) = (1 - 2 * negative) .* str2double(regexprep(p, '^[+-]', ''));
    end
    for k = reshape(find(~plain), 1, [])
        x(k) = py_float(cells{k});
    end
end

function x = py_float(cp)
% float(str) / np.str_.astype(float): Python's float grammar.
    t = cp;
    % Non-ASCII whitespace becomes ' ' and Unicode decimal digits ASCII
    % digits (_PyUnicode_TransformDecimalAndSpaceToASCII); then ASCII
    % whitespace (space, \t \n \v \f \r) is stripped.
    t(t > 127 & is_space(t)) = 32;
    zeros_ = [48, 1632, 1776, 1984, 2406, 2534, 2662, 2790, 2918, 3046, 3174, 3302, 3430, 3558, ...
        3664, 3792, 3872, 4160, 4240, 6112, 6160, 6470, 6608, 6784, 6800, 6992, 7088, 7232, 7248, ...
        42528, 43216, 43264, 43472, 43504, 43600, 44016, 65296, 66720, 68912, 69734, 69872, 69942, ...
        70096, 70384, 70736, 70864, 71248, 71360, 71472, 71904, 72016, 72784, 73040, 73120, 73552, ...
        92768, 92864, 93008, 120782, 120792, 120802, 120812, 120822, 123200, 123632, 124144, ...
        125264, 130032];
    for z = zeros_(2:end)
        hit = t >= z & t <= z + 9;
        t(hit) = t(hit) - z + 48;
    end
    ascii_space = t == 32 | (t >= 9 & t <= 13);
    first = find(~ascii_space, 1);
    last = find(~ascii_space, 1, 'last');
    t = t(first:last);
    s = char(t(t < 128));
    ok = numel(s) == numel(t) && ~isempty(s);
    if ok
        ok = ~isempty(regexp(s, ['^[+-]?(?:inf|infinity|nan|(?:\d(?:_?\d)*(?:\.(?:\d(?:_?\d)*)?)?', ...
            '|\.\d(?:_?\d)*)(?:[eE][+-]?\d(?:_?\d)*)?)$'], 'once', 'ignorecase'));
    end
    if ~ok
        error('panama_uav:trace', 'could not convert string to float: np.str_(%s)', py_repr(cp));
    end
    sign = 1;
    if s(1) == '-' || s(1) == '+'
        if s(1) == '-'
            sign = -1;
        end
        s = s(2:end);
    end
    word = lower(s);
    if strcmp(word, 'nan')
        x = NaN;
    elseif strcmp(word, 'inf') || strcmp(word, 'infinity')
        x = sign * Inf;
    else
        x = sign * str2double(strrep(s, '_', ''));
    end
end

function r = py_repr(cp)
% repr(str) for the error message; non-ASCII is escaped (see header).
    if any(cp == 39) && ~any(cp == 34)
        q = '"';
    else
        q = '''';
    end
    parts = cell(1, numel(cp));
    for k = 1:numel(cp)
        c = cp(k);
        if c == 92
            parts{k} = '\\';
        elseif c == 9
            parts{k} = '\t';
        elseif c == 10
            parts{k} = '\n';
        elseif c == 13
            parts{k} = '\r';
        elseif c == double(q)
            parts{k} = ['\', q];
        elseif c >= 32 && c < 127
            parts{k} = char(c);
        elseif c < 256
            parts{k} = sprintf('\\x%02x', c);
        elseif c < 65536
            parts{k} = sprintf('\\u%04x', c);
        else
            parts{k} = sprintf('\\U%08x', c);
        end
    end
    r = [q, parts{:}, q];
end

function p = resolved(source)
% str(Path(source).resolve()).
    p = panama_uav.util.absolute_path(source);
    if panama_uav.util.is_octave()
        p = canonicalize_file_name(p);
    elseif usejava('jvm')
        p = char(java.io.File(p).getCanonicalPath());
    end
end

function j = metadata_json(m, first_cp, last_cp, source_cp)
% json.dumps(metadata): default separators, ensure_ascii, float repr.
    f = @json_float;
    if isempty(m.column_names)
        names = 'null';
    else
        names = ['[', strjoin(cellfun(@(c) json_str(double(c)), m.column_names, 'UniformOutput', false), ', '), ']'];
    end
    j = ['{"source": ', json_str(source_cp), ...
        ', "source_sha256": ', json_str(double(m.source_sha256)), ...
        ', "direction": ', json_str(double(m.direction)), ...
        ', "source_unit": ', json_str(double(m.source_unit)), ...
        ', "stored_unit": "seconds"', ...
        ', "source_first_timestamp": ', json_str(first_cp), ...
        ', "source_last_timestamp": ', json_str(last_cp), ...
        ', "segment_start_seconds": ', f(m.segment_start_seconds), ...
        ', "segment_end_seconds": ', f(m.segment_end_seconds), ...
        ', "rows": ', sprintf('%d', m.rows), ...
        ', "column_names": ', names, ...
        ', "time_origin_seconds": ', f(m.time_origin_seconds), ...
        ', "missing_sequences_are_loss": false', ...
        ', "replacement_scope": "entire satellite backhaul hop; access remains modeled"', ...
        ', "handover_identification": "not inferred from delay spikes"}'];
    j = double(j);
end

function s = json_float(x)
% json.dumps of a float: repr, except NaN, Infinity and -Infinity.
    if isnan(x)
        s = 'NaN';
    elseif isinf(x) && x > 0
        s = 'Infinity';
    elseif isinf(x)
        s = '-Infinity';
    else
        s = panama_uav.util.py_float_repr(x);
    end
end

function s = json_str(cp)
% A JSON string literal with json.dumps(ensure_ascii=True) escapes.
    parts = cell(1, numel(cp));
    for k = 1:numel(cp)
        c = cp(k);
        switch c
            case 34, parts{k} = '\"';
            case 92, parts{k} = '\\';
            case 10, parts{k} = '\n';
            case 13, parts{k} = '\r';
            case 9, parts{k} = '\t';
            case 8, parts{k} = '\b';
            case 12, parts{k} = '\f';
            otherwise
                if c < 32 || (c > 126 && c < 65536)
                    parts{k} = sprintf('\\u%04x', c);
                elseif c >= 65536
                    v = c - 65536;
                    parts{k} = sprintf('\\u%04x\\u%04x', 55296 + floor(v / 1024), 56320 + mod(v, 1024));
                else
                    parts{k} = char(c);
                end
        end
    end
    s = ['"', parts{:}, '"'];
end
