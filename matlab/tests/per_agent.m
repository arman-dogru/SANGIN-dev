function c = per_agent(x, n)
%PER_AGENT Split a jsondecode'd per-agent list into a 1-by-n cell.
%   jsondecode turns equal-length nested lists into an n-by-... numeric
%   array and ragged ones into a cell; this undoes either form.
    if iscell(x)
        c = reshape(x, 1, []);
        return;
    end
    c = cell(1, n);
    if isempty(x)
        return;
    end
    sz = size(x);
    if sz(1) ~= n && n == 1
        x = reshape(x, [1 sz]);
        sz = size(x);
    end
    for a = 1:n
        c{a} = reshape(x(a, :), [sz(2:end) 1]);
    end
end
