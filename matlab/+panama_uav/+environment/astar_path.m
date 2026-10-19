function path = astar_path(grid, start, goal)
%ASTAR_PATH 4-connected A* on GRID (src/panama_uav/environment.py:astar_path).
%   PATH = panama_uav.environment.astar_path(GRID, START, GOAL) returns a
%   K-by-2 list of zero-based [row col] cells from START to GOAL, or
%   zeros(0,2) when GOAL is unreachable. Ties are broken exactly like the
%   Python heapq frontier: by f = g + h, then by insertion counter, and
%   neighbours are expanded in the order up, down, left, right.
    start = double(start(:)');
    goal = double(goal(:)');
    if isequal(start, goal)
        path = start;
        return;
    end
    [height, width] = size(grid);
    costs = inf(height, width);
    came = zeros(height, width);           % linear index of predecessor
    costs(start(1) + 1, start(2) + 1) = 0;
    cap = 4 * height * width + 1;
    F = inf(cap, 1);                       % frontier keys; inf marks popped
    R = zeros(cap, 1);
    C = zeros(cap, 1);
    G = zeros(cap, 1);
    n = 1;
    F(1) = abs(start(1) - goal(1)) + abs(start(2) - goal(2));
    R(1) = start(1);
    C(1) = start(2);
    moves = [-1 0; 1 0; 0 -1; 0 1];
    while true
        [best, k] = min(F(1:n));           % first minimum = smallest counter
        if isinf(best)
            break;
        end
        F(k) = inf;
        r = R(k);
        c = C(k);
        if r == goal(1) && c == goal(2)
            path = zeros(0, 2);
            idx = sub2ind([height width], r + 1, c + 1);
            first = sub2ind([height width], start(1) + 1, start(2) + 1);
            while true
                [rr, cc] = ind2sub([height width], idx);
                path(end + 1, :) = [rr - 1, cc - 1]; %#ok<AGROW>
                if idx == first
                    break;
                end
                idx = came(idx);
            end
            path = flipud(path);
            return;
        end
        next_cost = costs(r + 1, c + 1) + 1;
        for m = 1:4
            nr = r + moves(m, 1);
            nc = c + moves(m, 2);
            if nr < 0 || nr >= height || nc < 0 || nc >= width
                continue;
            end
            if grid(nr + 1, nc + 1) ~= 0 || next_cost >= costs(nr + 1, nc + 1)
                continue;
            end
            costs(nr + 1, nc + 1) = next_cost;
            came(nr + 1, nc + 1) = sub2ind([height width], r + 1, c + 1);
            n = n + 1;
            F(n) = next_cost + abs(nr - goal(1)) + abs(nc - goal(2));
            R(n) = nr;
            C(n) = nc;
            G(n) = next_cost;
        end
    end
    path = zeros(0, 2);
end
