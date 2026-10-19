classdef InformationCache < handle
    %INFORMATIONCACHE Monotonic receiver cache (src/panama_uav/information.py:InformationCache).
    properties
        timestamp = -inf
        value = []
        version = -1
        source_ids = zeros(1, 0)    % peers of source_timestamps (empty = None)
        source_times = zeros(1, 0)
    end
    methods
        function ok = accept(obj, timestamp, value, version, source_ids, source_times)
            if nargin < 4
                version = 0;
            end
            if nargin < 6
                source_ids = zeros(1, 0);
                source_times = zeros(1, 0);
            end
            if timestamp < obj.timestamp || (timestamp == obj.timestamp && version <= obj.version)
                ok = false;
                return;
            end
            obj.timestamp = timestamp;
            obj.value = value;
            obj.version = version;
            obj.source_ids = source_ids;
            obj.source_times = source_times;
            ok = true;
        end
        function a = age(obj, now)
            a = max(0.0, now - obj.oldest());
        end
        function t = oldest(obj)
            if isempty(obj.source_times)
                t = obj.timestamp;
            else
                t = min(obj.source_times);
            end
        end
    end
end
