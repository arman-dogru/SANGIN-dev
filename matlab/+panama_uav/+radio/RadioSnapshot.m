classdef RadioSnapshot
    %RADIOSNAPSHOT Radio quality map (src/panama_uav/radio.py:RadioSnapshot).
    properties
        quality_db   % single H-by-W SNR map
        normalized   % single H-by-W normalized quality
    end
    methods
        function obj = RadioSnapshot(quality_db, normalized)
            obj.quality_db = quality_db;
            obj.normalized = normalized;
        end
        function v = at_positions(obj, positions)
            %AT_POSITIONS SNR at zero-based [row col] positions (N-by-2).
            if isempty(positions)
                v = zeros(0, 1);
                return;
            end
            idx = sub2ind(size(obj.quality_db), positions(:, 1) + 1, positions(:, 2) + 1);
            v = double(obj.quality_db(idx));
        end
    end
end
