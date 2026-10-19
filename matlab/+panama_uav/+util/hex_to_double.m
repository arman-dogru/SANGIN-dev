function x = hex_to_double(h)
%HEX_TO_DOUBLE Exact double from 16 big-endian IEEE-754 hex digits (fixture helper).
%   Used because Octave's jsondecode does not round decimal floats correctly.
    if iscell(h)
        x = cellfun(@panama_uav.util.hex_to_double, h);
        return;
    end
    hi = uint32(sscanf(h(1:8), '%x'));
    lo = uint32(sscanf(h(9:16), '%x'));
    x = typecast([lo hi], 'double');
end
