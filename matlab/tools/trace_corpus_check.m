function trace_corpus_check(corpus_path, results_path)
%TRACE_CORPUS_CHECK Import every file of a trace_corpus.py corpus with
%   panama_uav.transport.import_trace and write one JSON line per file:
%   {"ok": true, "metadata": "<json.dumps-compatible text>"} or
%   {"ok": false, "id": ..., "message": ...}. See trace_corpus.py.
    corpus = jsondecode(panama_uav.util.read_text(corpus_path));
    if isstruct(corpus)
        corpus = num2cell(corpus);
    end
    fid = fopen(results_path, 'w');
    cleaner = onCleanup(@() fclose(fid));
    for k = 1:numel(corpus)
        c = corpus{k};
        p = c.params;
        try
            m = panama_uav.transport.import_trace(c.source, c.output, p.direction, p.unit, ...
                opt(p.start), opt(p.stop), opt(p.origin));
            line = struct('ok', true, 'metadata', jsonencode(m));
        catch err
            line = struct('ok', false, 'id', err.identifier, 'message', err.message);
        end
        fprintf(fid, '%s\n', jsonencode(line));
    end
end

function v = opt(x)
    if isempty(x)
        v = [];
    else
        v = panama_uav.util.hex_to_double(x);
    end
end
