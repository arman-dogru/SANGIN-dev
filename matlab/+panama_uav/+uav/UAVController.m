classdef UAVController < handle
    %UAVCONTROLLER UAV placement controller (src/panama_uav/uav.py:UAVController).
    %   Positions are [x y z] metres; robot cells are zero-based [row col].
    properties
        map_shape
        meters_per_cell
        config
        model
        map_width_m
        map_height_m
        position
        target_position
        total_distance_m
    end
    methods
        function obj = UAVController(map_shape, meters_per_cell, config)
            obj.map_shape = map_shape;
            obj.meters_per_cell = meters_per_cell;
            obj.config = config;
            obj.model = panama_uav.uav.AirToGroundModel(config);
            obj.map_width_m = map_shape(2) * meters_per_cell;
            obj.map_height_m = map_shape(1) * meters_per_cell;
            obj.reset();
        end
        function reset(obj)
            obj.position = [obj.map_width_m / 2.0, obj.map_height_m / 2.0, obj.model.optimal_height_m];
            obj.target_position = obj.position;
            obj.total_distance_m = 0.0;
        end
        function [target, best_mask] = optimal_target(obj, points)
            if isempty(points)
                target = obj.position;
                best_mask = false(0, 1);
                return;
            end
            radius = obj.model.maximum_radius_m;
            n = size(points, 1);
            candidates = points;
            for i = 1:n
                for j = i + 1:n
                    p1 = points(i, :);
                    p2 = points(j, :);
                    delta = p2 - p1;
                    distance = sqrt(sum(delta .^ 2));
                    if distance <= 1e-12 || distance > 2.0 * radius
                        continue;
                    end
                    midpoint = (p1 + p2) / 2.0;
                    offset = sqrt(max(radius ^ 2 - (distance / 2.0) ^ 2, 0.0));
                    perpendicular = [-delta(2), delta(1)] / distance;
                    candidates(end + 1, :) = midpoint + offset * perpendicular; %#ok<AGROW>
                    candidates(end + 1, :) = midpoint - offset * perpendicular; %#ok<AGROW>
                end
            end
            best_key = [];
            best_center = points(1, :);
            best_mask = false(n, 1);
            for k = 1:size(candidates, 1)
                center = candidates(k, :);
                distances = sqrt(sum((points - center) .^ 2, 2));
                covered = distances <= radius + 1e-8;
                count = sum(covered);
                if count
                    required = max(distances(covered));
                else
                    required = inf;
                end
                movement = sqrt(sum((center - obj.position(1:2)) .^ 2));
                key = [-count, required, movement, center(1), center(2)];
                if isempty(best_key) || lexless(key, best_key)
                    best_key = key;
                    best_center = center;
                    best_mask = covered;
                end
            end
            if any(best_mask)
                required = max(sqrt(sum((points(best_mask, :) - best_center) .^ 2, 2)));
            else
                required = 0.0;
            end
            height = max(obj.config.minimum_altitude_m, obj.model.alpha_opt * required);
            height = min(height, obj.model.optimal_height_m);
            target = [best_center(1), best_center(2), height];
        end
        function d = update(obj, points)
            [target, oracle] = obj.optimal_target(points);
            obj.target_position = target;
            direction = target - obj.position;
            distance = sqrt(sum(direction .^ 2));
            moved = min(obj.config.speed_m_per_step, distance);
            if distance > 1e-12
                obj.position = obj.position + direction * (moved / distance);
            end
            obj.total_distance_m = obj.total_distance_m + moved;
            if ~isempty(points)
                horizontal = sqrt(sum((points - obj.position(1:2)) .^ 2, 2));
                actual = obj.model.effective_snr_db(obj.position(3), horizontal) ...
                    >= obj.config.blackout_threshold_db;
            else
                actual = false(0, 1);
            end
            d = struct('target_position', target, 'distance_moved', moved, ...
                'oracle_served', sum(oracle), 'actual_served', sum(actual), ...
                'tracking_error_m', sqrt(sum((target - obj.position) .^ 2)));
        end
        function s = snapshot(obj)
            h = obj.map_shape(1);
            w = obj.map_shape(2);
            ys = ((0:h - 1)' + 0.5) * obj.meters_per_cell;
            xs = ((0:w - 1) + 0.5) * obj.meters_per_cell;
            horizontal = sqrt((repmat(xs, h, 1) - obj.position(1)) .^ 2 ...
                + (repmat(ys, 1, w) - obj.position(2)) .^ 2);
            snr = obj.model.effective_snr_db(obj.position(3), horizontal);
            s = panama_uav.radio.RadioSnapshot(single(snr), ...
                panama_uav.radio.normalize_quality(snr, obj.config.blackout_threshold_db, 30.0));
        end
        function xy = positions_to_xy_m(obj, positions)
            if isempty(positions)
                xy = zeros(0, 2);
                return;
            end
            xy = [(positions(:, 2) + 0.5) * obj.meters_per_cell, ...
                (positions(:, 1) + 0.5) * obj.meters_per_cell];
        end
    end
end

function tf = lexless(a, b)
    k = find(a ~= b, 1);
    tf = ~isempty(k) && a(k) < b(k);
end
