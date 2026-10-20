classdef NpyTest < matlab.unittest.TestCase
    % read_npy on .npy files written by NumPy (make_fixtures.py:group_npy):
    % header versions 1.0-3.0, float64/float32/int/uint/bool/string dtypes,
    % 0-d to 3-d shapes in C and Fortran order, and the refusals.
    methods (Test)
        function testFilesMatchNumPy(tc)
            % Values exact (tolerance 0, class-strict): the reader copies
            % bytes; expected values are the little-endian bytes NumPy holds.
            fx = load_fixture('npy');
            cases = as_cell(fx.cases);
            tc.verifyEqual(numel(cases), 23);
            folder = tempname();
            mkdir(folder);
            cleaner = onCleanup(@() rmdir(folder, 's'));
            loaded = 0;
            for k = 1:numel(cases)
                c = cases{k};
                path = fullfile(folder, sprintf('case%02d.npy', k));
                fid = fopen(path, 'w');
                fwrite(fid, hex_bytes(c.hex));
                fclose(fid);
                if isfield(c, 'error')
                    % NumPy: "EOF: reading array data, ..."; the port refuses too.
                    verify_error_message(tc, @() panama_uav.util.read_npy(path), 'panama_uav:npy', ...
                        sprintf('Truncated data in %s', path), c.name);
                elseif isfield(c, 'port_error')
                    % NumPy loads big-endian data; the port refuses it, as documented.
                    verify_error_message(tc, @() panama_uav.util.read_npy(path), 'panama_uav:npy', ...
                        c.port_error, c.name);
                else
                    % A valid NumPy file that the reader rejects is a parity
                    % failure, so an error here fails the check, not the run.
                    try
                        got = panama_uav.util.read_npy(path);
                    catch err
                        tc.verifyTrue(false, sprintf('%s: %s', c.name, err.message));
                        continue;
                    end
                    loaded = loaded + 1;
                    tc.verifyEqual(got, expected(c), c.name);
                end
            end
            tc.verifyEqual(loaded, 16);
        end
    end
end

function v = expected(c)
    switch c.class
        case 'char'
            v = utf8(as_cell(c.strings_hex));
            v = v{1};
        case 'cell'
            v = reshape(utf8(as_cell(c.strings_hex)), reshape(c.size, 1, []));
        case 'logical'
            v = reshape(hex_bytes(c.le) ~= 0, reshape(c.size, 1, []));
        otherwise
            v = reshape(typecast(hex_bytes(c.le), c.class), reshape(c.size, 1, []));
    end
end

function s = utf8(hexes)
    s = cellfun(@(h) panama_uav.util.decode_utf8(hex_bytes(h)), hexes, 'UniformOutput', false);
end

function b = hex_bytes(h)
    if isempty(h)
        b = zeros(1, 0, 'uint8');
    else
        b = uint8(hex2dec(reshape(h, 2, [])'))';
    end
end
