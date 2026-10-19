function out = plot_rollout(varargin)
%PLOT_ROLLOUT Map, robot trajectories and information age of one rollout.
%   out = plot_rollout() runs a 6-agent episode (seed 3) on maps/random-32-32-10.map
%   with all three mission inputs stale (UAV route, 10-step reservation
%   delay), using a scripted policy that follows each robot's *cached*
%   guidance, and writes matlab/output/rollout.png (gitignored).
%   Options: 'agents', 'seed', 'delay_steps', 'steps', 'output', and
%   'draw' (false: simulate only, no figure). The defaults are chosen so the
%   information-age panel is not empty: max_age is 10 (PlotRolloutTest);
%   the earlier 4 agents / seed 21 gave max_age 0.
%
%   This is a plumbing/visual check of the ported simulator, not a study
%   result: the policy is scripted, not the trained PANAMA DQN (milestone M2).
    here = fileparts(fileparts(mfilename('fullpath')));
    root = fileparts(here);
    opts = struct('agents', 6, 'seed', 3, 'delay_steps', 10, 'steps', 120, ...
        'output', fullfile(here, 'output', 'rollout.png'), 'draw', true);
    opts = panama_uav.util.parse_options(opts, varargin, 'plot_rollout');
    c = panama_uav.config.load_config(fullfile(root, 'configs', 'base.toml'));
    c = panama_uav.config.with_communication(c, 'stale_information', ...
        {'task', 'intentions', 'priorities'}, 'delay_steps', opts.delay_steps);
    env = panama_uav.environment.ExperimentEnvironment(c, 'maps/random-32-32-10.map', ...
        opts.agents, 250, opts.seed);
    env.reset();
    n = opts.agents;
    track = {reshape([env.agents.position], 2, [])'};
    ages = zeros(0, n);
    moves = [-1 0; 1 0; 0 -1; 0 1];
    for t = 1:opts.steps
        actions = 4 * ones(1, n);
        for k = 1:n
            g = env.communication.caches{k}.task.value.route;
            p = env.agents(k).position;
            if ~isempty(g)
                d = g(1, :) - p;
                m = find(moves(:, 1) == sign(d(1)) & moves(:, 2) == 0 & d(2) == 0 ...
                    | moves(:, 2) == sign(d(2)) & moves(:, 1) == 0 & d(1) == 0, 1);
                if isempty(m)       % off the cached route: step toward its next waypoint
                    if abs(d(1)) >= abs(d(2)), m = 1 + (d(1) > 0); else, m = 3 + (d(2) > 0); end
                end
                actions(k) = m - 1;
            end
        end
        r = env.step(actions);
        track{end + 1} = r.info.agent_positions; %#ok<AGROW>
        ages(end + 1, :) = r.info.communication.information_age(:, 1)'; %#ok<AGROW>
        if r.terminated || r.truncated
            break;
        end
    end
    out = struct('path', opts.output, 'steps', size(ages, 1), 'terminated', r.terminated, ...
        'max_age', max([0; ages(:)]));
    if ~opts.draw                  % simulation only (used by PlotRolloutTest)
        out.path = '';
        return;
    end
    positions = cat(3, track{:});
    if panama_uav.util.is_octave() && any(strcmp(available_graphics_toolkits(), 'gnuplot'))
        graphics_toolkit('gnuplot');   % headless Octave: OpenGL toolkits need a display
    end
    fig = figure('Visible', 'off', 'Position', [100 100 1100 480]);
    subplot(1, 2, 1);
    imagesc(1 - double(env.grid));
    colormap(gray);
    axis image;
    hold on;
    colors = lines(n);
    for k = 1:n
        rows = squeeze(positions(k, 1, :)) + 1;
        cols = squeeze(positions(k, 2, :)) + 1;
        plot(cols, rows, '-', 'Color', colors(k, :), 'LineWidth', 1.5);
        plot(cols(1), rows(1), 'o', 'Color', colors(k, :), 'MarkerFaceColor', colors(k, :));
        plot(env.agents(k).goal(2) + 1, env.agents(k).goal(1) + 1, 'p', 'Color', colors(k, :), ...
            'MarkerSize', 12, 'MarkerFaceColor', colors(k, :));
    end
    title(sprintf('random-32-32-10: %d robots, stale inputs, %g-step holds', n, opts.delay_steps));
    subplot(1, 2, 2);
    hold on;
    for k = 1:n
        stairs(1:size(ages, 1), ages(:, k), 'Color', colors(k, :), 'LineWidth', 1.2);
    end
    xlabel('robot step');
    ylabel('task guidance age (s)');
    title('Information age at the robot');
    grid on;
    legend(arrayfun(@(k) sprintf('robot %d', k - 1), 1:n, 'UniformOutput', false), 'Location', 'northwest');
    folder = fileparts(opts.output);
    if ~exist(folder, 'dir')
        mkdir(folder);
    end
    print(fig, opts.output, '-dpng', '-r110');
    close(fig);
end
