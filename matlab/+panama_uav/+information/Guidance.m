classdef Guidance < handle
    %GUIDANCE Cached absolute A* route (src/panama_uav/information.py:Guidance).
    properties
        route              % K-by-2 zero-based [row col]
        reported_distance
    end
    methods
        function obj = Guidance(route, reported_distance)
            obj.route = reshape(route, [], 2);
            obj.reported_distance = reported_distance;
        end
        function path = consume(obj, position)
            %CONSUME Drop waypoints up to the first visit of POSITION and return
            %   [POSITION; remaining route]; there is no local replanning.
            position = double(position(:)');
            if ~isempty(obj.route)
                k = find(obj.route(:, 1) == position(1) & obj.route(:, 2) == position(2), 1);
                if ~isempty(k)
                    obj.route = obj.route(k + 1:end, :);
                end
            end
            path = [position; obj.route];
        end
    end
end
