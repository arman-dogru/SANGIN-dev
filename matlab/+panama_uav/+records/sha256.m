function h = sha256(path)
%SHA256 SHA-256 of a file's bytes, as lowercase hex (records.py:sha256).
%   H = panama_uav.records.sha256(PATH) is
%   hashlib.sha256(Path(PATH).read_bytes()).hexdigest(). A missing file
%   raises panama_uav:records (Python: FileNotFoundError). The digest is
%   computed by panama_uav.util.sha256_bytes.
    fid = fopen(path, 'r');
    if fid < 0 || exist(path, 'dir')
        if fid >= 0
            fclose(fid);
        end
        error('panama_uav:records', 'No such file: %s', path);
    end
    bytes = fread(fid, Inf, '*uint8');
    fclose(fid);
    h = panama_uav.util.sha256_bytes(bytes);
end
