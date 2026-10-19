function c = profile(c, name)
%PROFILE Training profile (src/panama_uav/config.py:ProjectConfig.profile).
%   'full' returns C unchanged; 'smoke' shrinks the training budget.
    switch name
        case 'full'
            return;
        case 'smoke'
            t = c.training;
            t.target_environment_steps = 256;
            t.batch_size = 8;
            t.replay_capacity = 512;
            t.checkpoint_interval_steps = 32;
            t.budget_seconds = 120;
            t.shutdown_reserve_seconds = 5;
            c.training = t;
        otherwise
            error('panama_uav:config', 'Unknown profile %s', name);
    end
end
