function d = manhattan(a, b)
%MANHATTAN L1 distance between [row col] positions (environment.py:manhattan).
    d = abs(a(1) - b(1)) + abs(a(2) - b(2));
end
