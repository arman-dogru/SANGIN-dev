function p = absolute_path(path)
%ABSOLUTE_PATH Absolute version of PATH relative to the current folder.
    if panama_uav.util.is_absolute(path)
        p = path;
    else
        p = fullfile(pwd, path);
    end
end
