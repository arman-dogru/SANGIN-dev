classdef Xorshift128 < handle
    %XORSHIFT128 Portable seeded generator with identical streams on MATLAB and Octave.
    %   g = panama_uav.util.Xorshift128(seed) implements Marsaglia's xorshift128
    %   with uint32 shifts and xors only (no multiplication, which saturates for
    %   MATLAB integer types). MATLAB's RandStream and Octave's rand('twister')
    %   seed and permute differently, so this class is what makes the same seed
    %   give the same episodes on both. matlab/tools/make_fixtures.py holds a
    %   pure-Python reference (group "rng") that the tests compare against.
    %
    %   It replaces NumPy's np.random.default_rng (PCG64) only distributionally:
    %   a MATLAB episode with seed s is NOT the NumPy episode with seed s. For
    %   bit-identical episodes, inject the NumPy draws (see PORT_PLAN.md §5).
    properties
        state = zeros(1, 4, 'uint32')
    end
    methods
        function obj = Xorshift128(seed)
            seed = double(seed);
            if seed < 0 || seed ~= floor(seed) || seed >= 2 ^ 53
                error('panama_uav:rng', 'Seed must be an integer in [0, 2^53)');
            end
            lo = uint32(mod(seed, 2 ^ 32));
            hi = uint32(floor(seed / 2 ^ 32));
            obj.state = [bitxor(lo, uint32(123456789)), bitxor(hi, uint32(362436069)), ...
                uint32(521288629), uint32(88675123)];
            for k = 1:64            % warm-up decorrelates nearby seeds
                obj.next_uint32();
            end
        end
        function r = next_uint32(obj)
            %NEXT_UINT32 Marsaglia (2003) xor128: t = x^(x<<11); w = w^(w>>19)^t^(t>>8).
            s = obj.state;
            t = bitxor(s(1), bitshift(s(1), 11));
            t = bitxor(t, bitshift(t, -8));
            w = s(4);
            r = bitxor(bitxor(w, bitshift(w, -19)), t);
            obj.state = [s(2), s(3), s(4), r];
        end
        function u = rand(obj)
            %RAND Uniform double in [0, 1) with 53 random bits.
            a = double(bitshift(obj.next_uint32(), -5));   % 27 bits
            b = double(bitshift(obj.next_uint32(), -6));   % 26 bits
            u = (a * 67108864 + b) / 9007199254740992;
        end
        function k = randint(obj, n)
            %RANDINT Uniform integer in 0..n-1.
            k = floor(obj.rand() * n);
        end
        function p = permutation(obj, n)
            %PERMUTATION Uniform permutation of 1..n (Fisher-Yates, last to first).
            p = 1:n;
            for i = n:-1:2
                j = obj.randint(i) + 1;
                tmp = p(i);
                p(i) = p(j);
                p(j) = tmp;
            end
        end
        function v = choice(obj, n, k)
            %CHOICE K distinct values from 1..n (partial Fisher-Yates).
            p = 1:n;
            for i = 1:k
                j = i + obj.randint(n - i + 1);
                tmp = p(i);
                p(i) = p(j);
                p(j) = tmp;
            end
            v = p(1:k);
        end
    end
    methods (Static)
        function obj = from_state(state)
            %FROM_STATE Generator with the raw state [x y z w], no seed mixing
            %   and no warm-up. from_state([123456789 362436069 521288629
            %   88675123]) is Marsaglia's published xor128 and yields
            %   3701687786, 458299110, 2500872618, ... (RngTest pins this).
            state = double(state);
            if numel(state) ~= 4 || any(state < 0 | state >= 2 ^ 32 | state ~= floor(state)) ...
                    || all(state == 0)
                error('panama_uav:rng', 'State must be four uint32 values, not all zero');
            end
            obj = panama_uav.util.Xorshift128(0);
            obj.state = uint32(reshape(state, 1, 4));
        end
    end
end
