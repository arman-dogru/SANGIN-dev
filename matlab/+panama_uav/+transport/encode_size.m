function n = encode_size(value)
%ENCODE_SIZE Byte-exact length of Python's transport.encode(value).
%   N = panama_uav.transport.encode_size(VALUE) is len(encode(VALUE)) for
%   src/panama_uav/transport.py:encode, i.e. a pickle protocol-5 dump by
%   CPython's C pickler with fast mode on (no memo, so no PUT/MEMOIZE
%   opcodes and repeated values are written out each time). Only the size
%   is computed; no bytes are produced. The reference is transport.encode,
%   not pickle.dumps: dumps memoizes, so a value that occurs twice is
%   written once and then fetched by BINGET, and its pickle is shorter.
%
%   MATLAB values stand for Python values as follows (anything else raises
%   panama_uav:notImplemented, because its Python type would be a guess):
%     []  (0-by-0 double)              None
%     logical scalar                    bool
%     integer-class scalar (int8..int64, uint8..uint64)   int
%     double scalar                     float (always; 3.0 is a float)
%     char row or ''                    str (length counted in UTF-8 bytes)
%     panama_uav.transport.PyBytes(N)   bytes of length N
%     cell row or {}                    list
%     panama_uav.transport.PyTuple(...) tuple
%     scalar struct                     dict with str keys, in field order
%     panama_uav.transport.PyDict(K, V) dict with keys of any type (int-keyed
%                                       mission dicts), in insertion order
%     panama_uav.transport.PyTupleRows(M)  list of tuples of ints, one per
%                                       row of M (A* paths)
%     panama_uav.transport.PyInstance(MODULE, QUALNAME, STATE)  an instance
%                                       of a plain class such as the
%                                       information.Guidance dataclass
%   Numeric arrays, struct arrays and column cells are refused: their
%   Python type (tuple, list, NumPy array) would be a guess. The mission
%   payloads are mapped onto these types by
%   panama_uav.information.mission_wire.
%
%   An instance is saved as object.__reduce_ex__(5) gives it for a class
%   without __slots__ or __getstate__ (copyreg.__newobj__, (cls,), __dict__):
%   save(cls), which is save_global: save(MODULE), save(QUALNAME),
%   STACK_GLOBAL; then save(()) (EMPTY_TUPLE) and NEWOBJ; then save(STATE)
%   and BUILD. Fast mode has no memo, so nothing is fetched back by BINGET.
%
%   The frame accounting copies CPython 3.13 Modules/_pickle.c: the 2-byte
%   PROTO header sits outside any frame; a frame is opened by the first
%   write after it and carries a 9-byte FRAME header, dropped again if the
%   frame ends up shorter than 4 bytes; save() commits the open frame at
%   each opcode boundary once it holds 64 KiB; a str or bytes payload of
%   64 KiB or more commits the frame and is written outside any frame.
%   Lists and dicts are written in batches of 1000; a dict whose size is a
%   positive multiple of 1000 gets one extra empty MARK SETITEMS batch
%   (batch_dict_exact loops while the last batch was full), a list does not.
    s = struct('len', 0, 'fs', -1, 'framing', false);
    s = write(s, 2);                 % PROTO 5
    s.framing = true;
    s = save(s, value);
    s = write(s, 1);                 % STOP
    s = commit(s);
    n = s.len;
end

function s = save(s, v)
    s = boundary(s);
    if isobject(v)
        s = save_object(s, v);
    elseif ischar(v) && (isrow(v) || isequal(size(v), [0 0]))
        m = utf8_length(v);
        if m <= 255
            s = write_bytes(s, 2, m);            % SHORT_BINUNICODE
        else
            s = write_bytes(s, 5, m);            % BINUNICODE
        end
    elseif isa(v, 'double') && isequal(size(v), [0 0])
        s = write(s, 1);                         % NONE
    elseif islogical(v) && isscalar(v)
        s = write(s, 1);                         % NEWTRUE / NEWFALSE
    elseif isa(v, 'double') && isscalar(v) && isreal(v)
        s = write(s, 9);                         % BINFLOAT
    elseif isinteger(v) && isscalar(v)
        s = write(s, int_size(v));
    elseif iscell(v) && (isrow(v) || isequal(size(v), [0 0]))
        s = write(s, 1);                         % EMPTY_LIST
        k = numel(v);
        if k == 1
            s = save(s, v{1});
            s = write(s, 1);                     % APPEND
        elseif k > 1
            total = 0;
            while total < k
                s = write(s, 1);                 % MARK
                batch = 0;
                while total < k
                    total = total + 1;
                    s = save(s, v{total});
                    batch = batch + 1;
                    if batch == 1000
                        break;
                    end
                end
                s = write(s, 1);                 % APPENDS
            end
        end
    elseif isstruct(v) && isscalar(v)
        keys = fieldnames(v);
        s = save_dict(s, keys, cellfun(@(f) v.(f), keys, 'UniformOutput', false));
    else
        error('panama_uav:notImplemented', ['encode_size: no Python type for a %s of size %s ', ...
            '(use PyTuple, PyTupleRows, PyDict or PyInstance; mission payloads go through ', ...
            'panama_uav.information.mission_wire). ', ...
            'See matlab/PORT_PLAN.md.'], ...
            class(v), mat2str(size(v)));
    end
end

function s = save_object(s, v)
    % The typed stand-ins for Python values (save() has passed the boundary).
    if isa(v, 'panama_uav.transport.PyBytes')
        if v.n <= 255
            s = write_bytes(s, 2, v.n);          % SHORT_BINBYTES
        else
            s = write_bytes(s, 5, v.n);          % BINBYTES
        end
    elseif isa(v, 'panama_uav.transport.PyTuple')
        items = v.items;
        k = numel(items);
        if k == 0
            s = write(s, 1);                     % EMPTY_TUPLE
        elseif k <= 3
            for j = 1:k
                s = save(s, items{j});
            end
            s = write(s, 1);                     % TUPLE1/2/3
        else
            s = write(s, 1);                     % MARK
            for j = 1:k
                s = save(s, items{j});
            end
            s = write(s, 1);                     % TUPLE
        end
    elseif isa(v, 'panama_uav.transport.PyDict')
        s = save_dict(s, v.keys, v.values);
    elseif isa(v, 'panama_uav.transport.PyTupleRows')
        s = save_tuple_rows(s, v.rows);
    elseif isa(v, 'panama_uav.transport.PyInstance')
        s = boundary(s);                         % save(cls) -> save_global
        s = save(s, v.module);
        s = save(s, v.qualname);
        s = write(s, 1);                         % STACK_GLOBAL
        s = boundary(s);                         % save(())
        s = write(s, 1);                         % EMPTY_TUPLE
        s = write(s, 1);                         % NEWOBJ
        s = save(s, v.state);
        s = write(s, 1);                         % BUILD
    else
        error('panama_uav:notImplemented', 'encode_size: no Python type for a %s', class(v));
    end
end

function s = save_dict(s, keys, values)
    % save_dict: EMPTY_DICT, then batch_dict_exact.
    s = write(s, 1);                             % EMPTY_DICT
    k = numel(keys);
    if k == 1
        s = save(s, keys{1});
        s = save(s, values{1});
        s = write(s, 1);                         % SETITEM
    elseif k > 1
        pos = 0;
        batch = 1000;
        while batch == 1000
            s = write(s, 1);                     % MARK
            batch = 0;
            while pos < k
                pos = pos + 1;
                s = save(s, keys{pos});
                s = save(s, values{pos});
                batch = batch + 1;
                if batch == 1000
                    break;
                end
            end
            s = write(s, 1);                     % SETITEMS
        end
    end
end

function s = save_tuple_rows(s, m)
    % A list of int tuples, sized as save_list over save_tuple(save_long ...)
    % would size it. The list's own save() has already passed its opcode
    % boundary. Every nested save() is an opcode boundary too, but none can
    % commit the frame while the frame holds less than 64 KiB, so when the
    % whole list fits in the open frame its size is added at once;
    % otherwise each row's tuple and int goes through boundary().
    [n, k] = size(m);
    % save_long sizes, vectorized for signed 32-bit values (BININT1/2/BININT).
    x = double(m);
    sizes = 5 * ones(n, k);
    sizes(x >= 0 & x <= 65535) = 3;
    sizes(x >= 0 & x <= 255) = 2;
    if isa(m, 'uint64')
        wide = find(m > uint64(2147483647));
    else
        wide = find(int64(m) < int64(-2147483648) | int64(m) > int64(2147483647));
    end
    for j = reshape(wide, 1, [])
        sizes(j) = int_size(int64_or_uint64(m(j)));      % LONG1
    end
    if k == 0
        tuple_extra = 1;                         % EMPTY_TUPLE
    elseif k <= 3
        tuple_extra = 1;                         % TUPLE1/2/3
    else
        tuple_extra = 2;                         % MARK ... TUPLE
    end
    row_bytes = sum(sizes, 2) + tuple_extra;
    if n == 0
        list_extra = 1;                          % EMPTY_LIST
    elseif n == 1
        list_extra = 2;                          % EMPTY_LIST, APPEND
    else
        list_extra = 1 + 2 * ceil(n / 1000);     % EMPTY_LIST, MARK ... APPENDS per batch
    end
    total = sum(row_bytes) + list_extra;
    held = 0;
    if s.framing && s.fs >= 0
        held = s.len - s.fs - 9;
    end
    if ~s.framing || held + total <= 65536
        s = write(s, total);
        return;
    end
    s = write(s, 1);                             % EMPTY_LIST
    for j = 1:n
        if n > 1 && mod(j - 1, 1000) == 0
            s = write(s, 1);                     % MARK
        end
        s = boundary(s);                         % save(tuple)
        if k > 3
            s = write(s, 1);                     % MARK
        end
        for i = 1:k
            s = boundary(s);                     % save(int)
            s = write(s, sizes(j, i));
        end
        s = write(s, 1);                         % TUPLE*, EMPTY_TUPLE
        if n == 1
            s = write(s, 1);                     % APPEND
        elseif mod(j, 1000) == 0 || j == n
            s = write(s, 1);                     % APPENDS
        end
    end
end

function w = int64_or_uint64(x)
    if isa(x, 'uint64') || isa(x, 'int64')
        w = x;
    elseif x > 9223372036854775807
        w = uint64(x);
    else
        w = int64(x);
    end
end

function m = int_size(v)
    % save_long: BININT1/BININT2/BININT for a signed 32-bit value, else LONG1.
    if isa(v, 'uint64')
        small = v <= uint64(2147483647);
    else
        w = int64(v);
        small = w >= int64(-2147483648) && w <= int64(2147483647);
    end
    if small
        x = double(v);
        if x >= 0 && x <= 255
            m = 2;
        elseif x >= 0 && x <= 65535
            m = 3;
        else
            m = 5;
        end
        return;
    end
    negative = ~isa(v, 'uint64') && int64(v) < 0;
    if isa(v, 'uint64')
        mag = v;
    elseif int64(v) == intmin('int64')
        mag = bitshift(uint64(1), 63);
    else
        mag = uint64(abs(int64(v)));
    end
    power_of_two = bitand(mag, mag - 1) == 0;
    nbits = 0;
    while mag > 0
        mag = bitshift(mag, -1);
        nbits = nbits + 1;
    end
    nbytes = floor(nbits / 8) + 1;
    % -(2**(8j-1)) is its own 256's complement and needs no sign byte.
    if negative && power_of_two && mod(nbits, 8) == 0
        nbytes = nbytes - 1;
    end
    m = 2 + nbytes;                              % LONG1 <len> <bytes>
end

function m = utf8_length(v)
    c = double(v);
    if panama_uav.util.is_octave()
        m = numel(c);                            % Octave char holds UTF-8 bytes
    else
        surrogate = c >= 55296 & c <= 57343;     % a pair is 4 UTF-8 bytes, 2 per unit
        m = sum(c < 128) + 2 * sum(c >= 128 & c < 2048) + 3 * sum(c >= 2048 & ~surrogate) ...
            + 2 * sum(surrogate);
    end
end

function s = write(s, k)
    if s.framing && s.fs < 0
        s.fs = s.len;
        s.len = s.len + 9;                       % FRAME header, reserved
    end
    s.len = s.len + k;
end

function s = write_bytes(s, header, k)
    % _Pickler_write_bytes: payloads of 64 KiB or more bypass the frame.
    if k >= 65536
        s = commit(s);
        framing = s.framing;
        s.framing = false;
        s = write(s, header);
        s = write(s, k);
        s.framing = framing;
    else
        s = write(s, header);
        s = write(s, k);
    end
end

function s = commit(s)
    if ~s.framing || s.fs < 0
        return;
    end
    if s.len - s.fs - 9 < 4
        s.len = s.len - 9;                       % frame too short: no header
    end
    s.fs = -1;
end

function s = boundary(s)
    if s.framing && s.fs >= 0 && s.len - s.fs - 9 >= 65536
        s = commit(s);
    end
end
