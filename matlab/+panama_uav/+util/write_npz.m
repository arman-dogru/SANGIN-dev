function write_npz(path, names, members)
%WRITE_NPZ Write an .npz archive (a ZIP of .npy files) that np.load reads.
%   panama_uav.util.write_npz(PATH, NAMES, MEMBERS) stores MEMBERS{k}
%   (uint8, the bytes of an .npy file, e.g. from npy_bytes) as
%   '<NAMES{k}>.npy', in order. Entries are STORED (ZIP method 0) with
%   NumPy's fixed timestamp 1980-01-01 00:00, so the archive is the same
%   on every run. np.savez_compressed deflates its entries instead; zlib's
%   exact output is not reproduced (there is no toolbox-free deflate in
%   MATLAB), so the archive bytes differ from NumPy's while every member's
%   .npy bytes are identical. Archives of 4 GiB or more (ZIP64) are refused.
    local = cell(1, numel(names));
    central = cell(1, numel(names));
    offset = 0;
    for k = 1:numel(names)
        name = uint8([names{k}, '.npy']);
        data = reshape(uint8(members{k}), 1, []);
        crc = crc32(data);
        common = [le(20, 2), le(0, 2), le(0, 2), le(0, 2), le(33, 2), le(crc, 4), ...
            le(numel(data), 4), le(numel(data), 4), le(numel(name), 2), le(0, 2)];
        % version needed 2.0, no flags, stored, time 00:00, date 1980-01-01
        local{k} = [le(67324752, 4), common, name, data];                  % PK\3\4
        central{k} = [le(33639248, 4), le(20, 2), common, le(0, 2), le(0, 2), le(0, 2), ...
            le(0, 4), le(offset, 4), name];                                 % PK\1\2
        offset = offset + numel(local{k});
    end
    cd_bytes = [central{:}];
    if offset + numel(cd_bytes) >= 2^32
        error('panama_uav:npy', 'write_npz: archives of 4 GiB or more are not supported');
    end
    eocd = [le(101010256, 4), le(0, 2), le(0, 2), le(numel(names), 2), le(numel(names), 2), ...
        le(numel(cd_bytes), 4), le(offset, 4), le(0, 2)];                    % PK\5\6
    fid = fopen(path, 'w');
    if fid < 0
        error('panama_uav:io', 'Cannot write %s', path);
    end
    cleaner = onCleanup(@() fclose(fid));
    fwrite(fid, [local{:}, cd_bytes, eocd], 'uint8');
end

function b = le(x, n)
    b = zeros(1, n, 'uint8');
    x = double(x);
    for k = 1:n
        b(k) = mod(x, 256);
        x = floor(x / 256);
    end
end

function c = crc32(data)
    persistent table
    if isempty(table)
        table = zeros(1, 256);
        for i = 0:255
            r = i;
            for j = 1:8
                if bitand(r, 1)
                    r = bitxor(floor(r / 2), 3988292384);   % 0xEDB88320
                else
                    r = floor(r / 2);
                end
            end
            table(i + 1) = r;
        end
    end
    c = 4294967295;
    d = double(data);
    for k = 1:numel(d)
        c = bitxor(table(bitand(bitxor(c, d(k)), 255) + 1), floor(c / 256));
    end
    c = bitxor(c, 4294967295);
end
