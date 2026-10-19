function w = fixture_windows(x, n)
%FIXTURE_WINDOWS Per-agent K-by-2 window lists from jsondecode output.
%   jsondecode returns an n-by-K-by-2 array when every agent has K windows
%   and a cell array otherwise.
    w = cell(1, n);
    if iscell(x)
        for a = 1:n
            w{a} = reshape(x{a}, [], 2);
        end
    elseif isempty(x)
        w = {};
    else
        if ndims(x) == 2
            x = reshape(x, size(x, 1), 1, 2);
        end
        for a = 1:n
            w{a} = reshape(x(a, :, :), [], 2);
        end
    end
end
