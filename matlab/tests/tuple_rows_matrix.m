function m = tuple_rows_matrix(spec)
%TUPLE_ROWS_MATRIX The int64 N-by-K matrix of a make_fixtures.py
%   'tuple_rows' spec (a list of N int tuples of length K, |x| <= 2**53).
    rows = spec.rows;
    if iscell(rows)
        rows = cell2mat(cellfun(@(r) reshape(double(r), 1, []), rows(:), 'UniformOutput', false));
    end
    if spec.k == 0
        m = zeros(spec.n, 0, 'int64');
    else
        m = int64(reshape(rows, spec.n, spec.k));
    end
end
