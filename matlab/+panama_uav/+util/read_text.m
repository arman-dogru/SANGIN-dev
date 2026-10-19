function text = read_text(path)
%READ_TEXT Read a UTF-8 text file as a char row vector.
%   The bytes are validated as strictly as Python's open(...).read() /
%   tomllib.load: invalid UTF-8 raises panama_uav:utf8 with Python's
%   message (see panama_uav.util.decode_utf8).
    fid = fopen(path, 'r');
    if fid < 0
        error('panama_uav:io', 'Cannot open %s', path);
    end
    cleaner = onCleanup(@() fclose(fid));
    bytes = fread(fid, Inf, '*uint8')';
    text = panama_uav.util.decode_utf8(bytes);
end
