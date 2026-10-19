function toml_corpus_check(corpus_path, results_path)
%TOML_CORPUS_CHECK Decode every corpus document; one status line per document.
%   Called by matlab/tools/toml_corpus.py. Status is 'ok', or
%   'accept: ...', 'reject: ...', 'value: ...', 'location: ...' or
%   'crash: <identifier> <message>' for a mismatch.
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
        try
            got = panama_uav.util.canonical(panama_uav.util.toml_decode(d.text));
            if ~d.accepted
                status = 'accept: toml_decode accepted what tomllib rejects';
            elseif ~strcmp(got, d.canonical)
                status = ['value: ', got];
            end
        catch err
            if ~strcmp(err.identifier, 'panama_uav:toml')
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
