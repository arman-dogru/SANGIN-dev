function out = overlay(defaults, raw, section)
%OVERLAY Overlay decoded TOML values on a defaults struct.
%   Unknown keys raise panama_uav:config, as the Python dataclass(**raw)
%   constructor raises TypeError. int64 values become double; cell arrays of
%   numbers become row vectors; cell arrays of strings stay cell rows.
%
%   The int64 -> double conversion is deliberate: config values are used in
%   arithmetic with doubles everywhere downstream, and MATLAB integer
%   arithmetic saturates and rounds (int64(7) * 0.5 is 4), so keeping int64
%   is not safe. Integers are exact up to 2^53 = 9007199254740992; larger
%   magnitudes round to the nearest double (2^53 + 1 becomes 2^53). The
%   largest integers in use are 262,144 (configs/*.toml) and 80,000,000
%   (the target_environment_steps default). ConfigTest/
%   testIntegerOptionsBecomeDouble pins this.
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
