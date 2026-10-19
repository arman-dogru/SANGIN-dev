function toml_corpus_check(corpus_path, results_path)
%TOML_CORPUS_CHECK Decode every corpus document; one status line per document.
%   Called by matlab/tools/toml_corpus.py. Status is 'ok', or
%   'accept: ...', 'reject: ...', 'value: ...', 'location: ...', 'utf8: ...'
%   or 'crash: <identifier> <message>' for a mismatch. Documents are hex
%   bytes, decoded with panama_uav.util.decode_utf8 as read_text does.
    fx = jsondecode(panama_uav.util.read_text(corpus_path));
    docs = fx.docs;
    if isstruct(docs)
        docs = num2cell(docs);
    end
    fid = fopen(results_path, 'w');
    cleanup = onCleanup(@() fclose(fid));
    for k = 1:numel(docs)
        d = docs{k};
        status = 'ok';
        raw = uint8([]);
        if ~isempty(d.hex)                 % hex2dec of an empty char is not empty
            raw = uint8(hex2dec(reshape(d.hex, 2, [])'))';
        end
        try
            got = panama_uav.util.canonical(panama_uav.util.toml_decode(panama_uav.util.decode_utf8(raw)));
            if ~d.accepted
                status = 'accept: toml_decode accepted what tomllib rejects';
            elseif ~strcmp(got, d.canonical)
                status = ['value: ', got];
            end
        catch err
            if isfield(d, 'utf8')
                if ~strcmp(err.identifier, 'panama_uav:utf8') || ~strcmp(err.message, d.utf8)
                    status = ['utf8: ', err.identifier, ' ', err.message];
                end
            elseif ~strcmp(err.identifier, 'panama_uav:toml')
                status = ['crash: ', err.identifier, ' ', err.message];
            elseif d.accepted
                status = ['reject: ', err.message];
            else
                if strcmp(d.location, 'end of document')
                    want = 'at end of document:';
                else
                    want = ['on ', d.location, ':'];
                end
                if isempty(strfind(err.message, want))
                    status = ['location: ', err.message];
                end
            end
        end
        fprintf(fid, '%s\n', strrep(status, sprintf('\n'), ' '));
    end
end
