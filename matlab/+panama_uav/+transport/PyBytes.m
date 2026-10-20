classdef PyBytes
    %PYBYTES A Python bytes object of a known length, for encode_size.
    %   B = panama_uav.transport.PyBytes(N) stands for N bytes (Python's
    %   bytes(N) or any other N-byte value); only the length enters a pickle
    %   size, so the contents are not stored. A uint8 vector is not used for
    %   bytes because a uint8 scalar stands for a Python int.
    properties
        n = 0
    end
    methods
        function obj = PyBytes(n)
            if nargin > 0
                if ~isnumeric(n) || ~isscalar(n) || n < 0 || n ~= floor(n)
                    error('panama_uav:encode', 'PyBytes needs a nonnegative integer length');
                end
                obj.n = double(n);
            end
        end
    end
end
