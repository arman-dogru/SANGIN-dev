function tf = is_absolute(path)
%IS_ABSOLUTE True for /unix, \\unc and C:\ style absolute paths.
    tf = ~isempty(path) && (path(1) == '/' || path(1) == '\' || ...
        (numel(path) >= 3 && path(2) == ':' && (path(3) == '\' || path(3) == '/')));
end
