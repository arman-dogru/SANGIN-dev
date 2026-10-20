function text = decode_utf8(bytes)
%DECODE_UTF8 Strictly decode UTF-8 bytes into a char row, as Python does.
%   TEXT = panama_uav.util.decode_utf8(BYTES) rejects what Python's
%   bytes.decode('utf-8') rejects (invalid start bytes, overlong forms such
%   as C0 AF, surrogates ED A0..BF, code points above U+10FFFF, truncated
%   sequences) with error panama_uav:utf8 and Python's exact message, e.g.
%   "'utf-8' codec can't decode byte 0xff in position 5: invalid start byte".
%   On Octave, char is 8-bit and TEXT keeps the (validated) UTF-8 bytes; on
%   MATLAB, TEXT is UTF-16 (native2unicode).
    bytes = reshape(uint8(bytes), 1, []);
    if well_formed(bytes)
        high = [];                           % nothing to report: skip the scan below
    else
        high = find(bytes >= 128);           % find the first error, with Python's message
    end
    k = 1;
    while k <= numel(high)
        i = high(k);                         % 1-based start of a multibyte sequence
        b = double(bytes(i));
        if b >= 194 && b <= 223
            need = 1; lo = 128; hi = 191;
        elseif b >= 224 && b <= 239
            need = 2; lo = 128; hi = 191;
            if b == 224, lo = 160; elseif b == 237, hi = 159; end   % no overlongs, no surrogates
        elseif b >= 240 && b <= 244
            need = 3; lo = 128; hi = 191;
            if b == 240, lo = 144; elseif b == 244, hi = 143; end   % no overlongs, <= U+10FFFF
        else
            fail(bytes, i, i, 'invalid start byte');
        end
        for j = 1:need
            if i + j > numel(bytes)
                fail(bytes, i, i + j - 1, 'unexpected end of data');
            end
            c = double(bytes(i + j));
            if j == 1
                ok = c >= lo && c <= hi;
            else
                ok = c >= 128 && c <= 191;
            end
            if ~ok
                fail(bytes, i, i + j - 1, 'invalid continuation byte');
            end
        end
        k = k + need + 1;                    % the continuation bytes are the next entries of HIGH
    end
    if panama_uav.util.is_octave()
        text = char(bytes);
    else
        text = native2unicode(bytes, 'UTF-8');
    end
end

function ok = well_formed(bytes)
% Vectorised check that BYTES is valid UTF-8 (the same rules as the scan in
% decode_utf8): each lead byte C2..F4 is followed by exactly its 1 to 3
% continuation bytes 80..BF, with the narrower second-byte ranges after
% E0, ED, F0 and F4, and no other byte is >= 0x80.
    b = double(bytes);
    n = numel(b);
    if ~any(b >= 128)
        ok = true;
        return;
    end
    need = (b >= 194 & b <= 223) + 2 * (b >= 224 & b <= 239) + 3 * (b >= 240 & b <= 244);
    lead = find(need > 0);
    ok = all(b < 128 | need > 0 | (b >= 128 & b <= 191)) && all(lead + need(lead) <= n);
    if ~ok
        return;
    end
    expected = false(1, n);
    for j = 1:3
        at = lead(need(lead) >= j) + j;
        expected(at) = true;
    end
    ok = isequal(expected, b >= 128 & b <= 191);
    if ~ok
        return;
    end
    second = b(min(lead + 1, n));
    first = b(lead);
    ok = ~any((first == 224 & second < 160) | (first == 237 & second > 159) ...
        | (first == 240 & second < 144) | (first == 244 & second > 143));
end

function fail(bytes, first, last, reason)
% Python's UnicodeDecodeError text; positions are 0-based, LAST inclusive.
    if first == last
        error('panama_uav:utf8', '''utf-8'' codec can''t decode byte 0x%02x in position %d: %s', ...
            bytes(first), first - 1, reason);
    end
    error('panama_uav:utf8', '''utf-8'' codec can''t decode bytes in position %d-%d: %s', ...
        first - 1, last - 1, reason);
end
