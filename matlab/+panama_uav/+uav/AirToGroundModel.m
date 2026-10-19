classdef AirToGroundModel
    %AIRTOGROUNDMODEL Al-Hourani air-to-ground model (src/panama_uav/uav.py:AirToGroundModel).
    properties
        config
        a
        b
        eta_los
        eta_nlos
        alpha_opt
        maximum_radius_m
        optimal_height_m
    end
    methods
        function obj = AirToGroundModel(config)
            switch config.environment
                case 'suburban', p = [4.88, 0.43, 0.1, 21.0];
                case 'urban', p = [9.61, 0.16, 1.0, 20.0];
                case 'dense_urban', p = [12.08, 0.11, 1.6, 23.0];
                case 'highrise', p = [27.23, 0.08, 2.3, 34.0];
                otherwise
                    error('panama_uav:uav', 'Unknown UAV environment: %s', config.environment);
            end
            obj.config = config;
            obj.a = p(1);
            obj.b = p(2);
            obj.eta_los = p(3);
            obj.eta_nlos = p(4);
            obj.alpha_opt = obj.find_optimal_alpha();
            obj.maximum_radius_m = obj.radius_for_alpha(obj.alpha_opt);
            obj.optimal_height_m = obj.alpha_opt * obj.maximum_radius_m;
        end
        function p = los_probability(obj, alpha)
            angle_deg = atan(alpha) * (180 / pi);
            p = 1.0 ./ (1.0 + obj.a * exp(-obj.b * (angle_deg - obj.a)));
        end
        function r = radius_for_alpha(obj, alpha)
            c = 3e8;
            constant = 20.0 * log10(4.0 * pi * obj.config.carrier_frequency_hz / c) + obj.eta_nlos;
            excess = (obj.eta_los - obj.eta_nlos) * obj.los_probability(alpha);
            numerator = 10.0 ^ ((obj.config.max_path_loss_db - constant - excess) / 10.0);
            r = sqrt(numerator / (1.0 + alpha ^ 2));
        end
        function v = log_radius_derivative(obj, alpha)
            p = obj.los_probability(alpha);
            dp = p * (1.0 - p) * obj.b * (180.0 / pi) / (1.0 + alpha ^ 2);
            v = -(log(10.0) / 10.0) * (obj.eta_los - obj.eta_nlos) * dp - (2.0 * alpha / (1.0 + alpha ^ 2));
        end
        function alpha = find_optimal_alpha(obj)
            low = 1e-6;
            high = tan(89.9 * pi / 180);
            if obj.log_radius_derivative(low) <= 0 || obj.log_radius_derivative(high) >= 0
                error('panama_uav:uav', 'Could not bracket the air-to-ground optimum');
            end
            for k = 1:100 %#ok<FXUP>
                mid = (low + high) / 2.0;
                value = obj.log_radius_derivative(mid);
                if abs(value) < 1e-12
                    alpha = mid;
                    return;
                end
                if value > 0
                    low = mid;
                else
                    high = mid;
                end
            end
            alpha = (low + high) / 2.0;
        end
        function L = path_loss_db(obj, height_m, horizontal)
            height = max(double(height_m), 1e-6);
            alpha = height ./ max(horizontal, 1e-6);
            p = obj.los_probability(alpha);
            d3 = sqrt(horizontal .^ 2 + height ^ 2);
            free_space = 20.0 * log10(4.0 * pi * obj.config.carrier_frequency_hz / 3e8) ...
                + 20.0 * log10(max(d3, 1e-6));
            L = free_space + (p * obj.eta_los + (1.0 - p) * obj.eta_nlos);
        end
        function s = effective_snr_db(obj, height_m, horizontal)
            s = obj.config.blackout_threshold_db + (obj.config.max_path_loss_db ...
                - obj.path_loss_db(height_m, horizontal));
        end
    end
end
