function root = repo_root()
%REPO_ROOT Repository root (parent of matlab/).
    root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
end
