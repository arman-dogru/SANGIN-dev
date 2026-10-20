classdef PyDict
    %PYDICT A Python dict with keys of any type, for encode_size.
    %   D = panama_uav.transport.PyDict(KEYS, VALUES) holds the items in
    %   insertion order: KEYS and VALUES are cells of equal length, and KEYS{k}
    %   maps to VALUES{k}. A scalar struct already stands for a dict with str
    %   keys; PyDict is for the dicts keyed by agent id (int64 keys) in the
    %   mission payloads, and for any key MATLAB field names cannot hold.
    %   Keys are not checked for duplicates (Python would have merged them).
    properties
        keys = {}
        values = {}
    end
    methods
        function obj = PyDict(keys, values)
            if nargin == 0
                return;
            end
            if ~iscell(keys) || ~iscell(values) || numel(keys) ~= numel(values)
                error('panama_uav:encode', 'PyDict needs two cells of equal length (keys, values)');
            end
            obj.keys = reshape(keys, 1, []);
            obj.values = reshape(values, 1, []);
        end
    end
end
