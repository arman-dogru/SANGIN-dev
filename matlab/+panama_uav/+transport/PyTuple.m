classdef PyTuple
    %PYTUPLE A Python tuple for panama_uav.transport.encode_size.
    %   T = panama_uav.transport.PyTuple(A, B, ...) holds the items in order
    %   (T.items, a 1-by-N cell). MATLAB has no tuple type and a cell row
    %   already stands for a Python list, so tuples are explicit: a tuple
    %   and a list pickle to different opcodes (TUPLE1/2/3 or MARK ... TUPLE
    %   versus EMPTY_LIST ... APPENDS).
    properties
        items = {}
    end
    methods
        function obj = PyTuple(varargin)
            obj.items = varargin;
        end
    end
end
