function grid = load_map(path)
%LOAD_MAP Read a MovingAI .map file (src/panama_uav/scenarios.py:load_map).
%   GRID = panama_uav.scenarios.load_map(PATH) returns a uint8 matrix,
%   1 for obstacles ('@', 'T', 'O', '#') and 0 otherwise. Row r, column c
%   of GRID is Python grid[r-1, c-1].
    text = panama_uav.util.read_text(path);
    lines = regexp(text, '\r?\n', 'split');
    if ~isempty(lines) && isempty(lines{end})
        lines = lines(1:end - 1);
    end
    start = find(strcmp(lines, 'map'), 1);
    if isempty(start)
        error('panama_uav:map', 'Invalid MovingAI map without ''map'' marker: %s', path);
    end
    rows = lines(start + 1:end);
    widths = cellfun(@numel, rows);
    if isempty(rows) || any(widths ~= widths(1))
        error('panama_uav:map', 'Invalid or ragged map: %s', path);
    end
    chars = vertcat(rows{:});
    grid = uint8(chars == '@' | chars == 'T' | chars == 'O' | chars == '#');
end
