classdef PlotRolloutTest < matlab.unittest.TestCase
    % The on-demand figure's defaults must show staleness (README_MATLAB,
    % "Figure on demand"). Simulation only: no figure is drawn or written.
    methods (Test)
        function testDefaultsShowInformationAge(tc)
            addpath(fullfile(repo_root(), 'matlab', 'scripts'));
            out = plot_rollout('draw', false);
            tc.verifyTrue(out.max_age > 0, 'default rollout has an empty information-age panel');
            tc.verifyEqual(out.max_age, 10);
            tc.verifyEmpty(out.path);
        end
    end
end
