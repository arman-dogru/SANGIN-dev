function out = overlay(defaults, raw, section)
%OVERLAY Overlay decoded TOML values on a defaults struct.
%   Unknown keys raise panama_uav:config, as the Python dataclass(**raw)
%   constructor raises TypeError. int64 values become double; cell arrays of
%   numbers become row vectors; cell arrays of strings stay cell rows.
    out = defaults;
    names = fieldnames(raw);
    for k = 1:numel(names)
        key = names{k};
        if ~isfield(defaults, key)
            error('panama_uav:config', 'Unknown %s option "%s"', section, key);
        end
        out.(key) = normalize(raw.(key));
    end
end

function v = normalize(v)
    if isinteger(v)
        v = double(v);
    elseif iscell(v)
        if isempty(v)
            v = {};
        elseif all(cellfun(@(x) isnumeric(x) && isscalar(x), v))
            v = cellfun(@double, v);
        end
    end
end
