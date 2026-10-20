function cp = char_codepoints(s)
%CHAR_CODEPOINTS Unicode code points (double row) of a char row.
%   Octave chars are UTF-8 bytes (validated and decoded); MATLAB chars are
%   UTF-16 code units (surrogate pairs combined). See codepoints_char.
    if isempty(s)
        cp = zeros(1, 0);
        return;
    end
    if panama_uav.util.is_octave()
        bytes = uint8(double(s));
        panama_uav.util.decode_utf8(bytes);
        cp = panama_uav.util.utf8_codepoints(bytes);
    else
        u = double(reshape(s, 1, []));
        hi = find(u >= 55296 & u <= 56319 & [u(2:end) >= 56320 & u(2:end) <= 57343, false]);
        u(hi) = 65536 + (u(hi) - 55296) * 1024 + (u(hi + 1) - 56320);
        u(hi + 1) = [];
        cp = u;
    end
end
