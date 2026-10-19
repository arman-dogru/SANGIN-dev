function p = seeded_randperm(seed, n, k)
%SEEDED_RANDPERM Reproducible randperm without touching the global RNG state.
%   Uses RandStream on MATLAB and a saved/restored rand('twister') state on
%   Octave (which has no RandStream). Streams differ from NumPy's PCG64.
    if nargin < 3
        k = n;
    end
    seed = mod(double(seed), 2 ^ 32);
    if panama_uav.util.is_octave()
        old = rand('twister'); %#ok<RAND>
        cleaner = onCleanup(@() rand('twister', old)); %#ok<RAND>
        rand('twister', seed); %#ok<RAND>
        [~, order] = sort(rand(1, n));
        p = order(1:k);
    else
        stream = RandStream('twister', 'Seed', seed);
        p = randperm(stream, n, k);
    end
end
