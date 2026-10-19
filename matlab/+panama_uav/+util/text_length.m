function n = text_length(s)
%TEXT_LENGTH Number of Unicode code points in a char row, like Python len(str).
%   Octave's char is 8-bit, so decoded TOML and JSON text holds UTF-8 bytes
%   there ('é' is 2 chars, [195 169]); this counts the bytes that start a
%   code point. MATLAB's char is UTF-16, so 'é' is 1 char already; only
%   surrogate pairs (code points above U+FFFF) are counted once.
    v = double(s);
    if panama_uav.util.is_octave()
        n = sum(v < 128 | v >= 192);
    else
        n = numel(v) - sum(v >= 56320 & v <= 57343);
    end
end
