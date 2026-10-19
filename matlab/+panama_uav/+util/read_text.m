function text = read_text(path)
%READ_TEXT Read a UTF-8 text file as a char row vector.
    fid = fopen(path, 'r', 'n', 'UTF-8');
    if fid < 0
        error('panama_uav:io', 'Cannot open %s', path);
    end
    cleaner = onCleanup(@() fclose(fid));
    text = fread(fid, Inf, '*char')';
end
