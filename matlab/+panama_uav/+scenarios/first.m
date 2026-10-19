function s = first(s, num_agents)
%FIRST First NUM_AGENTS agents of a scenario (Scenario.first).
    if num_agents > size(s.starts, 1)
        error('panama_uav:scenario', '%s has %d agents, requested %d', s.path, ...
            size(s.starts, 1), num_agents);
    end
    s.starts = s.starts(1:num_agents, :);
    s.goals = s.goals(1:num_agents, :);
end
