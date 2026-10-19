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
                p = expect(p, ']]');
                data = append_table(data, keys);
                path = [keys, {'#last'}];
            else
                p.i = p.i + 1;
                [keys, p] = parse_key(p);
                p = expect(p, ']');
                data = ensure_table(data, keys);
                path = keys;
            end
            p = end_of_line(p);
        else
            [keys, p] = parse_key(p);
            p = skip_inline_ws(p);
            p = expect(p, '=');
            p = skip_inline_ws(p);
            [value, p] = parse_value(p);
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
        if c == ' ' || c == char(9) || c == char(10) || c == char(13)
            p.i = p.i + 1;
        elseif c == '#'
            while p.i <= numel(p.s) && p.s(p.i) ~= char(10)
                p.i = p.i + 1;
            end
        else
            break;
        end
    end
end

function p = end_of_line(p)
    p = skip_inline_ws(p);
    if p.i <= numel(p.s) && p.s(p.i) == '#'
        while p.i <= numel(p.s) && p.s(p.i) ~= char(10)
            p.i = p.i + 1;
        end
    end
    if p.i <= numel(p.s) && p.s(p.i) == char(13)
        p.i = p.i + 1;
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
    if p.i > numel(p.s)            % past the sentinel newline: tomllib says "at end of document"
        error('panama_uav:toml', 'TOML parse error at end of document: %s', message);
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
        if q == '"' && c == '\'
            q1 = p;
            q1.i = p.i + 1;
            e = peek(q1);
            switch e
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
    while true
        [keys, p] = parse_key(p);
        p = expect(p, '=');
        p = skip_inline_ws(p);
        [item, p] = parse_value(p);
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
    token = strrep(p.s(p.i:j - 1), '_', '');
    p.i = j;
    if isempty(token)
        fail(p, 'expected a value');
    end
    sign = 1;
    body = token;
    if body(1) == '+' || body(1) == '-'
        if body(1) == '-'
            sign = -1;
        end
        body = body(2:end);
    end
    if strcmp(body, 'inf')
        value = sign * Inf;
    elseif strcmp(body, 'nan')
        value = NaN;
    elseif numel(body) > 2 && body(1) == '0' && any(body(2) == 'xob')
        bases = struct('x', 16, 'o', 8, 'b', 2);
        value = int64(sign) * int64(base2dec_any(body(3:end), bases.(body(2))));
    elseif any(body == '.') || any(lower(body) == 'e')
        value = sign * str2double(body);
        if isnan(value)
            fail(p, ['invalid float ', token]);
        end
    else
        if ~all(isstrprop(body, 'digit'))
            fail(p, ['invalid value ', token]);
        end
        value = int64(sign) * parse_int64(body);
    end
end

function v = parse_int64(digits)
    v = int64(0);
    for k = 1:numel(digits)
        v = v * 10 + int64(digits(k) - '0');
    end
end

function v = base2dec_any(digits, base)
    v = int64(0);
    for k = 1:numel(digits)
        d = int64(find(lower(digits(k)) == '0123456789abcdef', 1) - 1);
        v = v * int64(base) + d;
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
