function s = canonical(value)
%CANONICAL Type-preserving canonical text of a decoded value.
%   S = panama_uav.util.canonical(VALUE) gives the same string that
%   matlab/tools/make_fixtures.py:canonical gives for the Python value, so
%   parity tests compare decoded TOML/JSON values including int/float type.
%   struct -> {k:v,...}; cell -> [..]; int -> i<n>; double -> f<%.17g>;
%   logical -> true/false; char -> s<len>:<text> with len in code points
%   (panama_uav.util.text_length); [] -> none.
    if isstruct(value)
        names = fieldnames(value);
        parts = cell(1, numel(names));
        for k = 1:numel(names)
            parts{k} = [names{k}, ':', panama_uav.util.canonical(value.(names{k}))];
        end
        s = ['{', strjoin(parts, ','), '}'];
    elseif iscell(value)
        parts = cellfun(@panama_uav.util.canonical, value, 'UniformOutput', false);
        s = ['[', strjoin(parts, ','), ']'];
    elseif islogical(value)
        if value, s = 'true'; else, s = 'false'; end
    elseif isinteger(value)
        s = ['i', sprintf('%d', value)];
    elseif ischar(value)
        s = sprintf('s%d:%s', panama_uav.util.text_length(value), value);   % code points, as Python
    elseif isempty(value)
        s = 'none';
    elseif isnumeric(value)
        if isinf(value)
            if value > 0, s = 'finf'; else, s = 'f-inf'; end
        elseif isnan(value)
            s = 'fnan';
        else
            s = ['f', sprintf('%.17g', value)];
        end
    else
        error('panama_uav:canonical', 'Unsupported type %s', class(value));
    end
end
