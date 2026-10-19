function c = as_cell(x)
%AS_CELL jsondecode gives struct arrays for uniform lists and cells otherwise.
    if iscell(x)
        c = reshape(x, 1, []);
    elseif isstruct(x)
        c = num2cell(reshape(x, 1, []));
    elseif isempty(x)
        c = {};
    else
        c = num2cell(reshape(x, 1, []));
    end
end
