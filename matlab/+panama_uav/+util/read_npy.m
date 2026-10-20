function value = read_npy(path)
%READ_NPY Read one NumPy .npy array (format versions 1.0, 2.0 and 3.0).
%   VALUE = panama_uav.util.read_npy(PATH) supports little-endian float64,
%   float32, int8..int64, uint8..uint64 and bool ('<f8', '<f4', '<i8', ...,
%   '|b1') and Unicode strings ('<U<n>', UTF-32LE, trailing NULs stripped
%   as NumPy does). Object arrays ('|O') are refused, like np.load with
%   allow_pickle=False, and so are big-endian arrays.
%
%   Shapes: a 0-d array gives a scalar (a char row for a string), a 1-d
%   array of N elements an N-by-1 column (an N-by-1 cellstr for strings),
%   and an n-d array an array of the same shape (C or Fortran order).
    fid = fopen(path, 'r', 'ieee-le');
    if fid < 0
        error('panama_uav:npy', 'Cannot open %s', path);
    end
    closer = onCleanup(@() fclose(fid));
    magic = fread(fid, 6, '*uint8')';
    if numel(magic) ~= 6 || ~isequal(magic, uint8([147 double('NUMPY')]))
        error('panama_uav:npy', '%s is not a .npy file', path);
    end
    version = fread(fid, 2, 'uint8')';
    if version(1) == 1
        header_length = fread(fid, 1, 'uint16');
    elseif version(1) == 2 || version(1) == 3
        header_length = fread(fid, 1, 'uint32');
    else
        error('panama_uav:npy', 'Unsupported .npy format version %d.%d', version(1), version(2));
    end
    header = char(fread(fid, header_length, 'uint8')');
    descr = regexp(header, '''descr''\s*:\s*''([^'']*)''', 'tokens', 'once');
    order = regexp(header, '''fortran_order''\s*:\s*(True|False)', 'tokens', 'once');
    shape = regexp(header, '''shape''\s*:\s*\(([^)]*)\)', 'tokens', 'once');
    if isempty(descr) || isempty(order) || isempty(shape)
        error('panama_uav:npy', 'Malformed .npy header in %s', path);
    end
    descr = descr{1};
    fortran = strcmp(order{1}, 'True');
    dims = sscanf(strrep(shape{1}, ',', ' '), '%d')';
    count = prod(dims);                          % prod([]) == 1 for a 0-d array
    if any(descr(1) == '>')
        error('panama_uav:npy', 'Big-endian arrays (%s) are not supported', descr);
    end
    code = descr(2:end);
    numeric = struct('f8', 'double', 'f4', 'single', 'i8', 'int64', 'i4', 'int32', ...
        'i2', 'int16', 'i1', 'int8', 'u8', 'uint64', 'u4', 'uint32', 'u2', 'uint16', ...
        'u1', 'uint8', 'b1', 'uint8');
    if code(1) == 'U'
        width = str2double(code(2:end));
        units = fread(fid, width * count, '*uint32');
        if numel(units) ~= width * count
            error('panama_uav:npy', 'Truncated data in %s', path);
        end
        units = reshape(units, width, count);
        strings = cell(count, 1);
        for k = 1:count
            cp = double(units(:, k))';
            last = find(cp ~= 0, 1, 'last');     % NumPy strips trailing NULs
            strings{k} = code_points_to_char(cp(1:last));
        end
        if isempty(dims)
            value = strings{1};
        else
            value = arrange(strings, dims, fortran);
        end
        return;
    end
    if code(1) == 'O'
        error('panama_uav:npy', 'Object arrays cannot be loaded when allow_pickle=False');
    end
    if ~isfield(numeric, code)
        error('panama_uav:npy', 'Unsupported dtype %s in %s', descr, path);
    end
    cls = numeric.(code);
    values = fread(fid, count, ['*', cls]);
    if numel(values) ~= count
        error('panama_uav:npy', 'Truncated data in %s', path);
    end
    if strcmp(code, 'b1')
        values = values ~= 0;
    end
    if isempty(dims)
        value = values(1);
    else
        value = arrange(values, dims, fortran);
    end
end

function value = arrange(values, dims, fortran)
    if numel(dims) == 1
        value = reshape(values, dims, 1);
    elseif fortran
        value = reshape(values, dims);
    else
        value = permute(reshape(values, fliplr(dims)), numel(dims):-1:1);
    end
end

function s = code_points_to_char(cp)
    if all(cp < 128)
        s = char(cp);
        return;
    end
    if panama_uav.util.is_octave()
        % Octave's char is 8-bit: hold the UTF-8 bytes.
        bytes = zeros(1, 0);
        for c = cp
            if c < 128
                bytes(end + 1) = c; %#ok<AGROW>
            elseif c < 2048
                bytes(end + (1:2)) = [192 + floor(c / 64), 128 + mod(c, 64)];
            elseif c < 65536
                bytes(end + (1:3)) = [224 + floor(c / 4096), 128 + mod(floor(c / 64), 64), 128 + mod(c, 64)];
            else
                bytes(end + (1:4)) = [240 + floor(c / 262144), 128 + mod(floor(c / 4096), 64), ...
                    128 + mod(floor(c / 64), 64), 128 + mod(c, 64)];
            end
        end
        s = char(bytes);
    else
        units = zeros(1, 0);
        for c = cp
            if c < 65536
                units(end + 1) = c; %#ok<AGROW>
            else
                c = c - 65536;
                units(end + (1:2)) = [55296 + floor(c / 1024), 56320 + mod(c, 1024)];
            end
        end
        s = char(units);
    end
end
