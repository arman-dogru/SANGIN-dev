function s = codepoints_char(cp)
%CODEPOINTS_CHAR A char row holding the Unicode code points CP.
%   On Octave, char is 8-bit and S holds the UTF-8 bytes (as decode_utf8
%   returns text); on MATLAB, S is UTF-16 (surrogate pairs above U+FFFF).
%   CP = char_codepoints(S) is the inverse.
    cp = double(reshape(cp, 1, []));
    if isempty(cp)
        s = '';
        return;
    end
    if panama_uav.util.is_octave()
        out = zeros(1, 4 * numel(cp));
        n = 0;
        for c = cp
            if c < 128
                u = c;
            elseif c < 2048
                u = [192 + floor(c / 64), 128 + mod(c, 64)];
            elseif c < 65536
                u = [224 + floor(c / 4096), 128 + mod(floor(c / 64), 64), 128 + mod(c, 64)];
            else
                u = [240 + floor(c / 262144), 128 + mod(floor(c / 4096), 64), ...
                    128 + mod(floor(c / 64), 64), 128 + mod(c, 64)];
            end
            out(n + (1:numel(u))) = u;
            n = n + numel(u);
        end
        s = char(out(1:n));
    else
        units = cell(1, numel(cp));
        for k = 1:numel(cp)
            c = cp(k);
            if c < 65536
                units{k} = c;
            else
                c = c - 65536;
                units{k} = [55296 + floor(c / 1024), 56320 + mod(c, 1024)];
            end
        end
        s = char([units{:}]);
    end
end
