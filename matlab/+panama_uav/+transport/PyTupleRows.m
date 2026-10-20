classdef PyTupleRows
    %PYTUPLEROWS A Python list of tuples of ints, one tuple per matrix row.
    %   L = panama_uav.transport.PyTupleRows(M) stands for
    %   [tuple(int(x) for x in row) for row in M], e.g. an A* path
    %   [(r0, c0), (r1, c1), ...] from an N-by-2 matrix of cell indices. It
    %   pickles exactly like a cell row of PyTuple(int64(...)) values, but
    %   encode_size sizes it without building one object per row. M must hold
    %   integer values; an empty M (any 0-by-K) is the empty list.
    properties
        rows = zeros(0, 2)
    end
    methods
        function obj = PyTupleRows(m)
            if nargin == 0
                return;
            end
            if ~(isnumeric(m) && isreal(m) && ismatrix(m)) || any(m(:) ~= round(m(:))) ...
                    || any(~isfinite(double(m(:))))
                error('panama_uav:encode', 'PyTupleRows needs a real matrix of integer values');
            end
            obj.rows = m;
        end
    end
end
