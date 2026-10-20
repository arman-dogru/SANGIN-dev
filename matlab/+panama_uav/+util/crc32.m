function c = crc32(data)
%CRC32 zlib.crc32 of a byte vector (the CRC-32 of ZIP and PNG).
%   C = panama_uav.util.crc32(DATA) is the CRC-32 (reflected polynomial
%   0xEDB88320, initial value and final XOR 0xFFFFFFFF) of the bytes DATA
%   (uint8 or 0..255 doubles), as a double, the value zlib.crc32 returns.
%
%   The byte-at-a-time recurrence is sequential, which an interpreter runs
%   slowly (about 1 us per byte on Octave). Here the bytes are split into
%   B blocks of L bytes, zero-padded at the front (leading zeros leave a
%   zero register unchanged), and the L steps run on all blocks at once.
%   The register update is linear over GF(2), so the block registers are
%   then chained with the 32 x 32 bit matrix of "L zero bytes", and the
%   initial value with the matrix of "N zero bytes" (repeated squaring).
    persistent table
    if isempty(table)
        r = (0:255)';
        for j = 1:8
            odd = bitand(r, 1);
            r = floor(r / 2);
            r(odd == 1) = bitxor(r(odd == 1), 3988292384);   % 0xEDB88320
        end
        table = uint32(r);
    end
    d = uint32(reshape(data, [], 1));
    n = numel(d);
    if n == 0
        c = 0;
        return;
    end
    len = max(1, ceil(sqrt(n)));
    blocks = ceil(n / len);
    d = reshape([zeros(blocks * len - n, 1, 'uint32'); d], len, blocks)';   % blocks x len
    reg = zeros(blocks, 1, 'uint32');
    for k = 1:len
        reg = bitxor(table(bitand(bitxor(reg, d(:, k)), 255) + 1), bitshift(reg, -8));
    end
    % Chain: R <- Z^len R xor reg(b), from R = 0.
    step = zero_bytes(len, table);
    bits = to_bits(reg);                                     % 32 x blocks
    acc = zeros(32, 1);
    for b = 1:blocks
        acc = xor(mod(step * acc, 2), bits(:, b));
    end
    % The initial 0xFFFFFFFF register, carried through all n bytes.
    init = mod(zero_bytes(n, table) * ones(32, 1), 2);
    c = bitxor(from_bits(xor(acc, init)), 4294967295);
end

function m = zero_bytes(count, table)
% The GF(2) matrix (32 x 32, double 0/1) of COUNT zero-byte steps.
    one = zeros(32);
    for j = 1:32
        v = uint32(2 ^ (j - 1));
        v = bitxor(table(bitand(v, 255) + 1), bitshift(v, -8));
        one(:, j) = to_bits(v);
    end
    m = eye(32);
    p = one;
    while count > 0
        if mod(count, 2) == 1
            m = mod(p * m, 2);
        end
        p = mod(p * p, 2);
        count = floor(count / 2);
    end
end

function b = to_bits(v)
% Columns of bits, least significant first.
    v = double(reshape(v, 1, []));
    b = zeros(32, numel(v));
    for j = 1:32
        b(j, :) = mod(v, 2);
        v = floor(v / 2);
    end
end

function v = from_bits(b)
    v = sum(double(b(:)) .* 2 .^ (0:31)');
end
