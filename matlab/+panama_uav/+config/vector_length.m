function n = vector_length(c)
%VECTOR_LENGTH Observation vector length (ProjectConfig.vector_length).
    n = 2 + 2 * c.map.astar_waypoints;
end
