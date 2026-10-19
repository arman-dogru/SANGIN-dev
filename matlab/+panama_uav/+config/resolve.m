function p = resolve(c, path)
%RESOLVE Resolve PATH against the project root (ProjectConfig.resolve).
    if panama_uav.util.is_absolute(path)
        p = path;
    else
        p = fullfile(c.project_root, path);
    end
end
