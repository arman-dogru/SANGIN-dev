function data = load_fixture(name)
%LOAD_FIXTURE Decode matlab/tests/fixtures/<name>.json (made by tools/make_fixtures.py).
    here = fileparts(mfilename('fullpath'));
    data = jsondecode(panama_uav.util.read_text(fullfile(here, 'fixtures', [name, '.json'])));
end
