classdef UavTest < matlab.unittest.TestCase
    % Parity: air-to-ground model and UAV controller (uav.py, radio.py).
    methods (Test)
        function testModelConstants(tc)
            fx = load_fixture('uav');
            c = panama_uav.config.defaults();
            m = panama_uav.uav.AirToGroundModel(c.uav);
            tc.verifyEqual(m.alpha_opt, fx.alpha_opt, 'RelTol', 1e-12);
            tc.verifyEqual(m.maximum_radius_m, fx.max_radius, 'RelTol', 1e-12);
            tc.verifyEqual(m.optimal_height_m, fx.optimal_height, 'RelTol', 1e-12);
            h = reshape(fx.horizontal, 1, []);
            tc.verifyEqual(m.path_loss_db(30.0, h), reshape(fx.path_loss_h30, 1, []), 'AbsTol', 1e-10);
            tc.verifyEqual(m.effective_snr_db(30.0, h), reshape(fx.snr_h30, 1, []), 'AbsTol', 1e-10);
        end
        function testControllerTrajectory(tc)
            fx = load_fixture('uav');
            c = panama_uav.config.defaults();
            u = panama_uav.uav.UAVController([32 32], 1.0, c.uav);
            steps = as_cell(fx.steps);
            for k = 1:numel(steps)
                s = steps{k};
                d = u.update(u.positions_to_xy_m(reshape(s.positions, [], 2)));
                tc.verifyEqual(u.position, reshape(s.position, 1, []), 'AbsTol', 1e-9);
                tc.verifyEqual(d.target_position, reshape(s.target, 1, []), 'AbsTol', 1e-9);
                tc.verifyEqual(d.distance_moved, s.moved, 'AbsTol', 1e-9);
                tc.verifyEqual(d.oracle_served, s.oracle);
                tc.verifyEqual(d.actual_served, s.actual);
            end
            snap = u.snapshot();
            tc.verifyEqual(double(snap.quality_db), fx.snapshot_quality, 'AbsTol', 1e-4);
            tc.verifyEqual(double(snap.normalized), fx.snapshot_normalized, 'AbsTol', 1e-6);
        end
    end
end
