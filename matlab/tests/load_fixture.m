function data = load_fixture(name)
%LOAD_FIXTURE Decode matlab/tests/fixtures/<name>.json or <name>.json.gz
%   (written by matlab/tools/make_fixtures.py).
    here = fileparts(mfilename('fullpath'));
    path = fullfile(here, 'fixtures', [name, '.json']);
    if ~exist(path, 'file')
        folder = tempname;
        mkdir(folder);
        cleaner = onCleanup(@() rmdir(folder, 's'));
        files = gunzip([path, '.gz'], folder);
        path = files{1};
    end
    data = jsondecode(panama_uav.util.read_text(path));
end
