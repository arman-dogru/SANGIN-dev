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
            tc.verifyEqual(m.path_loss_db(30.0, h), reshape(fx.path_loss_h30, 1, []), 'AbsTol', 1e-12);
            tc.verifyEqual(m.effective_snr_db(30.0, h), reshape(fx.snr_h30, 1, []), 'AbsTol', 1e-12);
        end
        function testControllerTrajectory(tc)
            fx = load_fixture('uav');
            c = panama_uav.config.defaults();
            u = panama_uav.uav.UAVController([32 32], 1.0, c.uav);
            steps = as_cell(fx.steps);
            for k = 1:numel(steps)
                s = steps{k};
                d = u.update(u.positions_to_xy_m(reshape(s.positions, [], 2)));
                % Measured differences are <= 1.4e-14 m (libm and jsondecode last bits).
                tc.verifyEqual(u.position, reshape(s.position, 1, []), 'AbsTol', 1e-12);
                tc.verifyEqual(d.target_position, reshape(s.target, 1, []), 'AbsTol', 1e-12);
                tc.verifyEqual(d.distance_moved, s.moved, 'AbsTol', 1e-12);
                tc.verifyEqual(d.tracking_error_m, s.tracking, 'AbsTol', 1e-12);
                tc.verifyEqual(d.oracle_served, s.oracle);
                tc.verifyEqual(d.actual_served, s.actual);
                q = u.snapshot().quality_db;
                cells = q(sub2ind(size(q), [0 5 16 31 31] + 1, [0 17 16 2 31] + 1));
                tc.verifyEqual(cells, single(reshape(s.snapshot_cells, 1, [])), sprintf('step %d snapshot', k));
                tc.verifyEqual(sum(double(q(:))), s.snapshot_sum, 'AbsTol', 1e-9, sprintf('step %d snapshot sum', k));
            end
            % float32 maps compared exactly at single precision.
            snap = u.snapshot();
            tc.verifyEqual(snap.quality_db, single(fx.snapshot_quality));
            tc.verifyEqual(snap.normalized, single(fx.snapshot_normalized));
        end
    end
end
