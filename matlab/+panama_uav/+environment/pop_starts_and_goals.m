function [starts, goals] = pop_starts_and_goals(cells, num_agents)
%POP_STARTS_AND_GOALS Python's pop order on already shuffled free cells.
%   [STARTS, GOALS] = panama_uav.environment.pop_starts_and_goals(CELLS, N)
%   takes the N-by-2 zero-based CELLS in shuffled order and pops from the end
%   as environment.py:_random_starts_and_goals does: each pair takes
%   first = cells(end), second = cells(end-1) with goals swapped, and an odd
%   last agent takes start = cells(end), goal = cells(end-1). An odd N needs
%   N + 1 cells (see the inherited off-by-one in
%   ExperimentEnvironment.random_starts_and_goals). RngTest replays the
%   Python-recorded shuffles in tests/fixtures/popping.json.
    starts = zeros(0, 2);
    goals = zeros(0, 2);
    for k = 1:floor(num_agents / 2)
        first = cells(end, :);
        second = cells(end - 1, :);
        cells = cells(1:end - 2, :);
        starts = [starts; first; second]; %#ok<AGROW>
        goals = [goals; second; first]; %#ok<AGROW>
    end
    if mod(num_agents, 2)
        starts(end + 1, :) = cells(end, :);
        goals(end + 1, :) = cells(end - 1, :);
    end
end
