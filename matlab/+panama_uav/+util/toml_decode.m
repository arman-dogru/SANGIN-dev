function data = toml_decode(text)
%TOML_DECODE Decode the TOML subset used by configs/*.toml.
%   DATA = panama_uav.util.toml_decode(TEXT) returns a struct. Replaces
%   Python's tomllib.loads (used by src/panama_uav/config.py:load_config).
%
%   Supported: [table], [a.b], [[array.of.tables]], bare/quoted and dotted
%   keys, basic and literal strings, integers (underscores, sign, 0x/0o/0b),
%   floats (exponents, inf, nan), booleans, arrays (nested, multiline,
%   trailing commas) and inline tables. Not supported: dates/times and
%   multiline strings (no config uses them); they raise an error.
%   Rejected like tomllib: malformed numbers (bare signs, leading zeros,
%   stray underscores, '1.', signed 0x), duplicate keys (also dotted keys
%   inside inline tables), tables declared twice, extending inline tables or
%   arrays of tables, a bare CR line ending, and control characters
%   (U+0000-U+001F except tab, U+007F; CR included) in strings, quoted keys
%   and comments. Invalid UTF-8 is rejected earlier, by read_text /
%   decode_utf8, with Python's message (TomlTest replays texts
%   recorded from tomllib, and matlab/tools/toml_corpus.py compares random
%   documents).
%
%   Differences from tomllib, on purpose or by platform:
%   - Integers outside int64 raise an error (the TOML spec requires it);
%     tomllib returns unbounded Python ints.
%   - On Octave, char is 8-bit, so strings hold their UTF-8 bytes ('é' is
%     [195 169]); panama_uav.util.text_length counts code points and
%     canonical uses it. On MATLAB, char is UTF-16 and 'é' is one char.
%   - Basic strings take the escapes \b \t \n \f \r \" and \\; \uXXXX and
%     \UXXXXXXXX escapes, multiline strings and dates/times are not
%     supported (they raise an error).
%
%   Representation: tables are structs, arrays are cell row vectors (so a
%   one-element array stays distinguishable from a scalar), integers are
%   int64, floats are double, booleans are logical, strings are char.
%   Arrays of tables are cell row vectors of structs.
    if ~ischar(text)
        text = char(text);
    end
    p.s = [text, char(10)];
    p.i = 1;
    data = struct();
    path = {};
    % Namespaces seen so far, as tomllib tracks them (ids from node_id):
    % explicit [table] headers, tables created by dotted keys, frozen
    % inline tables and arrays of tables.
    st = struct('tables', {{}}, 'dotted', {{}}, 'inline', {{}}, 'aot', {{}});
    while true
        p = skip_ws_comments_newlines(p);
        if p.i > numel(p.s)
            break;
        end
        c = p.s(p.i);
        if c == '['
            if p.i < numel(p.s) && p.s(p.i + 1) == '['
                p.i = p.i + 2;
                [keys, p] = parse_key(p);
                [kind, id] = lookup(data, keys, st);
                if strcmp(kind, 'value') || strcmp(kind, 'inline')
                    fail(p, 'cannot mutate an immutable value with [[...]]');
                elseif strcmp(kind, 'table')
                    fail(p, 'cannot overwrite a table with [[...]]');
                end
                p = expect(p, ']]');
                data = append_table(data, keys);
                st.aot{end + 1} = id;
                path = [keys, {'#last'}];
            else
                p.i = p.i + 1;
                [keys, p] = parse_key(p);
                [kind, id] = lookup(data, keys, st);
                if ~any(strcmp(kind, {'none', 'table'})) || any(strcmp(id, [st.tables, st.dotted]))
                    fail(p, 'cannot declare a table twice');
                end
                p = expect(p, ']');
                data = ensure_table(data, keys);
                st.tables{end + 1} = id;
                path = keys;
            end
            p = end_of_line(p);
        else
            [keys, p] = parse_key(p);
            p = skip_inline_ws(p);
            p = expect(p, '=');
            p = skip_inline_ws(p);
            [value, p] = parse_value(p);
            [st, p] = check_assign(data, path, keys, value, st, p);
            data = assign(data, [path, keys], value);
            p = end_of_line(p);
        end
    end
end

function p = skip_inline_ws(p)
    while p.i <= numel(p.s) && (p.s(p.i) == ' ' || p.s(p.i) == char(9))
        p.i = p.i + 1;
    end
end

function p = skip_ws_comments_newlines(p)
    while p.i <= numel(p.s)
        c = p.s(p.i);
        if c == char(13)
            p = crlf(p);
        elseif c == ' ' || c == char(9) || c == char(10)
            p.i = p.i + 1;
        elseif c == '#'
            p = skip_comment(p);
        else
            break;
        end
    end
end

function p = crlf(p)
% A CR is only allowed as part of CRLF; tomllib rejects a bare CR. The LF
% must be real text, not the sentinel newline appended to p.s.
    if p.i + 1 < numel(p.s) && p.s(p.i + 1) == char(10)
        p.i = p.i + 1;
    else
        fail(p, 'bare carriage return');
    end
end

function p = skip_comment(p)
    while p.i <= numel(p.s) && p.s(p.i) ~= char(10)
        if p.s(p.i) == char(13)
            p = crlf(p);
            return;
        end
        if is_control(p.s(p.i))
            fail(p, sprintf('invalid character 0x%02x in comment', double(p.s(p.i))));
        end
        p.i = p.i + 1;
    end
end

function tf = is_control(c)
% Characters tomllib rejects in strings, quoted keys and comments: U+0000
% to U+001F except tab, and U+007F. (LF ends the line and CR is only valid
% in CRLF; both are handled by the callers.)
    v = double(c);
    tf = (v < 32 && v ~= 9) || v == 127;
end

function p = end_of_line(p)
    p = skip_inline_ws(p);
    if p.i <= numel(p.s) && p.s(p.i) == '#'
        p = skip_comment(p);
    end
    if p.i <= numel(p.s) && p.s(p.i) == char(13)
        p = crlf(p);
    end
    if p.i <= numel(p.s) && p.s(p.i) ~= char(10)
        fail(p, 'expected end of line');
    end
end

function p = expect(p, token)
    p = skip_inline_ws(p);
    n = numel(token);
    if p.i + n - 1 > numel(p.s) || ~strcmp(p.s(p.i:p.i + n - 1), token)
        fail(p, ['expected "', token, '"']);
    end
    p.i = p.i + n;
end

function fail(p, message)
    % Newlines strictly before p.i, so an error at a line's own newline
    % reports that line, as tomllib does.
    if p.i >= numel(p.s)           % past the real text (p.s ends with a sentinel newline):
        error('panama_uav:toml', 'TOML parse error at end of document: %s', message);   % tomllib's wording
    end
    line = sum(p.s(1:p.i - 1) == char(10)) + 1;
    error('panama_uav:toml', 'TOML parse error on line %d: %s', line, message);
end

function c = peek(p)
% Character at p.i; a clean parse error (not an index error) at end of input.
    if p.i > numel(p.s)
        fail(p, 'unexpected end of document');
    end
    c = p.s(p.i);
end

function [keys, p] = parse_key(p)
    keys = {};
    while true
        p = skip_inline_ws(p);
        c = peek(p);
        if c == '"' || c == ''''
            [k, p] = parse_string(p);
        else
            j = p.i;
            while j <= numel(p.s) && (isstrprop(p.s(j), 'alphanum') || p.s(j) == '_' || p.s(j) == '-')
                j = j + 1;
            end
            if j == p.i
                fail(p, 'empty key');
            end
            k = p.s(p.i:j - 1);
            p.i = j;
        end
        keys{end + 1} = k; %#ok<AGROW>
        p = skip_inline_ws(p);
        if p.i <= numel(p.s) && p.s(p.i) == '.'
            p.i = p.i + 1;
        else
            break;
        end
    end
end

function [value, p] = parse_value(p)
    c = peek(p);
    if c == '"' || c == ''''
        [value, p] = parse_string(p);
    elseif c == '['
        [value, p] = parse_array(p);
    elseif c == '{'
        [value, p] = parse_inline_table(p);
    elseif startsWith(p.s(p.i:end), 'true')
        value = true;
        p.i = p.i + 4;
    elseif startsWith(p.s(p.i:end), 'false')
        value = false;
        p.i = p.i + 5;
    else
        [value, p] = parse_number(p);
    end
end

function [value, p] = parse_string(p)
    q = p.s(p.i);
    if p.i + 2 <= numel(p.s) && all(p.s(p.i:p.i + 2) == q)
        fail(p, 'multiline strings are not supported');
    end
    p.i = p.i + 1;
    out = '';
    while true
        if p.i > numel(p.s) || p.s(p.i) == char(10)
            fail(p, 'unterminated string');
        end
        c = p.s(p.i);
        if c == q
            p.i = p.i + 1;
            break;
        end
        if is_control(c)                   % includes CR: single-line strings have no CRLF
            fail(p, sprintf('illegal character 0x%02x in string', double(c)));
        end
        if q == '"' && c == '\'
            q1 = p;
            q1.i = p.i + 1;
            e = peek(q1);
            switch e
                case 'b', out(end + 1) = char(8); %#ok<AGROW>
                case 'f', out(end + 1) = char(12); %#ok<AGROW>
                case 'n', out(end + 1) = char(10); %#ok<AGROW>
                case 't', out(end + 1) = char(9); %#ok<AGROW>
                case 'r', out(end + 1) = char(13); %#ok<AGROW>
                case '"', out(end + 1) = '"'; %#ok<AGROW>
                case '\', out(end + 1) = '\'; %#ok<AGROW>
                otherwise
                    fail(p, 'unsupported escape');
            end
            p.i = p.i + 2;
        else
            out(end + 1) = c; %#ok<AGROW>
            p.i = p.i + 1;
        end
    end
    value = out;
end

function [value, p] = parse_array(p)
    p.i = p.i + 1;
    value = {};
    while true
        p = skip_ws_comments_newlines(p);
        if peek(p) == ']'
            p.i = p.i + 1;
            return;
        end
        [item, p] = parse_value(p);
        value{end + 1} = item; %#ok<AGROW>
        p = skip_ws_comments_newlines(p);
        if peek(p) == ','
            p.i = p.i + 1;
        elseif peek(p) == ']'
            p.i = p.i + 1;
            return;
        else
            fail(p, 'expected "," or "]" in array');
        end
    end
end

function [value, p] = parse_inline_table(p)
    p.i = p.i + 1;
    value = struct();
    p = skip_inline_ws(p);
    if peek(p) == '}'
        p.i = p.i + 1;
        return;
    end
    % Same namespace rules as at top level, relative to this inline table:
    % dotted keys may build sub-tables, but nothing is assigned twice and
    % nested inline tables are frozen.
    st = struct('tables', {{}}, 'dotted', {{}}, 'inline', {{}}, 'aot', {{}});
    while true
        [keys, p] = parse_key(p);
        p = expect(p, '=');
        p = skip_inline_ws(p);
        [item, p] = parse_value(p);
        [st, p] = check_assign(value, {}, keys, item, st, p);
        value = assign(value, keys, item);
        p = skip_inline_ws(p);
        if peek(p) == ','
            p.i = p.i + 1;
        elseif peek(p) == '}'
            p.i = p.i + 1;
            return;
        else
            fail(p, 'expected "," or "}" in inline table');
        end
    end
end

function [value, p] = parse_number(p)
    j = p.i;
    while j <= numel(p.s) && any(p.s(j) == '0123456789abcdefABCDEFxXoO_+-.ein')
        j = j + 1;
    end
    raw = p.s(p.i:j - 1);
    if isempty(raw)
        fail(p, 'expected a value');
    end
    % TOML number grammar, checked on the raw token like tomllib: underscores
    % only between digits, no leading zeros, digits on both sides of '.',
    % an exponent needs digits, and no sign on 0x/0o/0b.
    digits = '[0-9](_?[0-9])*';
    dec = '[+-]?(0|[1-9](_?[0-9])*)';
    if is_match(raw, '[+-]?(inf|nan)')
        kind = 'special';
    elseif is_match(raw, '0x[0-9A-Fa-f](_?[0-9A-Fa-f])*|0o[0-7](_?[0-7])*|0b[01](_?[01])*')
        kind = 'based';
    elseif is_match(raw, [dec, '(\.', digits, '([eE][+-]?', digits, ')?|[eE][+-]?', digits, ')'])
        kind = 'float';
    elseif is_match(raw, dec)
        kind = 'int';
    else
        fail(p, ['invalid value ', raw]);
    end
    at = p;                        % range errors point at the token, as other number errors do
    p.i = j;
    token = strrep(raw, '_', '');
    sign = 1;
    body = token;
    if body(1) == '+' || body(1) == '-'
        if body(1) == '-'
            sign = -1;
        end
        body = body(2:end);
    end
    switch kind
        case 'special'
            if strcmp(body, 'inf')
                value = sign * Inf;
            else
                value = NaN;
            end
        case 'based'
            bases = struct('x', 16, 'o', 8, 'b', 2);
            [value, ok] = base2dec_any(body(3:end), bases.(body(2)));
            if ~ok
                fail(at, ['integer out of int64 range ', raw]);
            end
        case 'float'
            value = sign * str2double(body);
        otherwise
            [value, ok] = parse_int64(body, sign);
            if ~ok
                fail(at, ['integer out of int64 range ', raw]);
            end
    end
end

function tf = is_match(text, pattern)
    tf = ~isempty(regexp(text, ['^(', pattern, ')$'], 'once'));
end

function [v, ok] = parse_int64(digits, sign)
% Exact signed decimal in [-2^63, 2^63-1]; OK is false outside it (the TOML
% spec requires an error, never a clamped value). int64 arithmetic
% saturates, so the range is checked on the digit string first.
    digits = regexprep(digits, '^0+(?=.)', '');
    limit = '9223372036854775807';
    if sign < 0
        limit = '9223372036854775808';
    end
    ok = numel(digits) < numel(limit) || (numel(digits) == numel(limit) && string_le(digits, limit));
    v = int64(0);
    if ~ok
        return;
    end
    if sign < 0 && strcmp(digits, limit)
        v = intmin('int64');
        return;
    end
    for k = 1:numel(digits)
        v = v * 10 + int64(digits(k) - '0');
    end
    if sign < 0
        v = -v;
    end
end

function tf = string_le(a, b)
% Equal-length digit strings: a <= b numerically.
    k = find(a ~= b, 1);
    tf = isempty(k) || a(k) < b(k);
end

function [v, ok] = base2dec_any(digits, base)
% Unsigned 0x/0o/0b value; OK is false above 2^63-1 instead of saturating.
% The range is checked on the digit string (Octave's int64 division goes
% through double, so arithmetic checks near 2^63 are not exact).
    v = int64(0);
    digits = regexprep(digits, '^0+(?=.)', '');
    width = struct('b16', 16, 'b8', 21, 'b2', 63);
    w = width.(sprintf('b%d', base));
    ok = numel(digits) < w || (numel(digits) == w && (base ~= 16 || lower(digits(1)) <= '7'));
    if ~ok
        return;
    end
    for k = 1:numel(digits)
        d = int64(find(lower(digits(k)) == '0123456789abcdef', 1) - 1);
        v = v * int64(base) + d;
    end
end

function [kind, id] = lookup(data, keys, st)
% What KEYS (a header path, '#last' entries ignored) names in DATA: 'none',
% 'table', 'aot' (array of tables), 'inline' (frozen inline table) or
% 'value'; ID is a namespace id with the array-of-tables index, like
% tomllib's key tuples.
    keys = keys(~strcmp(keys, '#last'));
    node = data;
    id = '';
    kind = 'table';
    for i = 1:numel(keys)
        k = keys{i};
        id = [id, char(31), k]; %#ok<AGROW>
        if ~strcmp(kind, 'table') || ~isfield(node, k)
            if ~strcmp(kind, 'table')
                return;            % below a value: report the value
            end
            kind = 'none';
            for r = i + 1:numel(keys)
                id = [id, char(31), keys{r}]; %#ok<AGROW>
            end
            return;
        end
        v = node.(k);
        if iscell(v) && any(strcmp(id, st.aot))
            if i == numel(keys)
                kind = 'aot';
                return;
            end
            id = sprintf('%s#%d', id, numel(v));
            node = v{end};
        elseif isstruct(v)
            node = v;
            if any(strcmp(id, st.inline))
                kind = 'inline';
            end
        else
            kind = 'value';
        end
    end
end

function [st, p] = check_assign(data, path, keys, value, st, p)
% tomllib's rules for KEYS = VALUE inside the table PATH.
    for i = 1:numel(keys) - 1          % dotted-key prefixes
        [kind, id] = lookup(data, [path, keys(1:i)], st);
        % A prefix through a plain value or an inline table is caught by the
        % final lookup below (lookup stops there), so only arrays of tables,
        % which lookup would descend into, need a check here.
        if strcmp(kind, 'inline') || strcmp(kind, 'aot')
            fail(p, 'cannot mutate an immutable namespace');
        elseif any(strcmp(id, st.tables))
            fail(p, 'cannot redefine a namespace with dotted keys');
        end
        if ~any(strcmp(id, st.dotted))
            st.dotted{end + 1} = id;
        end
    end
    [kind, id] = lookup(data, [path, keys], st);
    if ~strcmp(kind, 'none')
        fail(p, 'cannot overwrite a value');
    end
    if isstruct(value)
        st.inline{end + 1} = id;
    end
end

function data = ensure_table(data, keys)
    if isempty(keys)
        return;
    end
    k = keys{1};
    if ~isfield(data, k)
        data.(k) = struct();
    end
    if iscell(data.(k))
        data.(k){end} = ensure_table(data.(k){end}, keys(2:end));
    else
        data.(k) = ensure_table(data.(k), keys(2:end));
    end
end

function data = append_table(data, keys)
    k = keys{1};
    if numel(keys) == 1
        if ~isfield(data, k)
            data.(k) = {};
        end
        data.(k){end + 1} = struct();
        return;
    end
    if ~isfield(data, k)
        data.(k) = struct();
    end
    if iscell(data.(k))
        data.(k){end} = append_table(data.(k){end}, keys(2:end));
    else
        data.(k) = append_table(data.(k), keys(2:end));
    end
end

function data = assign(data, keys, value)
    k = keys{1};
    if strcmp(k, '#last')
        error('panama_uav:toml', 'internal path error');
    end
    if numel(keys) == 1
        data.(k) = value;
        return;
    end
    if ~isfield(data, k)
        data.(k) = struct();
    end
    if numel(keys) >= 2 && strcmp(keys{2}, '#last')
        data.(k){end} = assign(data.(k){end}, keys(3:end), value);
    elseif iscell(data.(k))
        data.(k){end} = assign(data.(k){end}, keys(2:end), value);
    else
        data.(k) = assign(data.(k), keys(2:end), value);
    end
end
