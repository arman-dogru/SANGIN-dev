function check_tagged(tc, got, want, label)
%CHECK_TAGGED Compare a MATLAB value with a value tagged by
%   make_fixtures.py:tagged ('f:<hex>' floats, compared bit for bit;
%   's:<text>' strings; plain numbers, booleans, lists and dicts).
    if ischar(want) && numel(want) >= 2 && strcmp(want(1:2), 'f:')
        tc.verifyTrue(isnumeric(got) && isscalar(got), [label, ' (float expected)']);
        if isnumeric(got) && isscalar(got)
            tc.verifyEqual(typecast(double(got), 'uint64'), ...
                typecast(panama_uav.util.hex_to_double(want(3:end)), 'uint64'), label);
        end
    elseif ischar(want) && numel(want) >= 2 && strcmp(want(1:2), 's:')
        tc.verifyEqual(got, want(3:end), label);
    elseif isstruct(want) && isscalar(want)
        tc.verifyTrue(isstruct(got), [label, ' (struct expected)']);
        if ~isstruct(got)
            return;
        end
        % jsondecode renames keys that are not valid MATLAB names (Python's
        % 'end' becomes 'xEnd') with matlab.lang.makeValidName; map ours alike.
        names = fieldnames(got);
        valid = cellfun(@matlab.lang.makeValidName, names, 'UniformOutput', false);
        tc.verifyEqual(sort(valid), sort(fieldnames(want)), [label, ' fields']);
        for j = 1:numel(names)
            if isfield(want, valid{j})
                check_tagged(tc, got.(names{j}), want.(valid{j}), [label, '.', names{j}]);
            end
        end
    elseif islogical(want)
        tc.verifyEqual(logical(got), want, label);
    elseif isempty(want)
        tc.verifyTrue(isempty(got), [label, ' (empty expected)']);
    elseif iscell(want) || (isnumeric(want) && numel(want) > 1) || iscell(got)
        w = as_cell(want);
        g = as_cell(got);
        tc.verifyEqual(numel(g), numel(w), [label, ' length']);
        for k = 1:min(numel(g), numel(w))
            check_tagged(tc, g{k}, w{k}, sprintf('%s{%d}', label, k));
        end
    else
        tc.verifyEqual(double(got), double(want), label);
    end
end
