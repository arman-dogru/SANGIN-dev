function h = sha256_bytes(bytes, method)
%SHA256_BYTES SHA-256 (FIPS 180-4) of a uint8 vector, as lowercase hex.
%   H = panama_uav.util.sha256_bytes(BYTES) uses a built-in digest when
%   there is one (Octave's hash('sha256', ...), or java.security.MessageDigest
%   on MATLAB with a JVM) and the portable implementation otherwise.
%   H = panama_uav.util.sha256_bytes(BYTES, 'portable') always uses the
%   portable implementation (plain double arithmetic on 32-bit words, no
%   toolbox), which RecordsTest checks against the built-ins, NIST's
%   examples and hashlib. It is slow (about 1 MB per few seconds on Octave).
    if nargin < 2
        method = 'auto';
    end
    bytes = reshape(uint8(bytes), 1, []);
    if strcmp(method, 'auto')
        if panama_uav.util.is_octave()
            h = hash('sha256', char(bytes));
            return;
        elseif usejava('jvm')
            md = java.security.MessageDigest.getInstance('SHA-256');
            d = typecast(int8(md.digest(typecast(bytes, 'int8'))), 'uint8');
            h = lower(reshape(dec2hex(d, 2)', 1, []));
            return;
        end
    elseif ~strcmp(method, 'portable')
        error('panama_uav:records', 'sha256_bytes: method must be ''auto'' or ''portable''');
    end
    h = portable(double(bytes));
end

function h = portable(m)
    K = [hex2dec({'428a2f98','71374491','b5c0fbcf','e9b5dba5','3956c25b','59f111f1','923f82a4','ab1c5ed5', ...
        'd807aa98','12835b01','243185be','550c7dc3','72be5d74','80deb1fe','9bdc06a7','c19bf174', ...
        'e49b69c1','efbe4786','0fc19dc6','240ca1cc','2de92c6f','4a7484aa','5cb0a9dc','76f988da', ...
        '983e5152','a831c66d','b00327c8','bf597fc7','c6e00bf3','d5a79147','06ca6351','14292967', ...
        '27b70a85','2e1b2138','4d2c6dfc','53380d13','650a7354','766a0abb','81c2c92e','92722c85', ...
        'a2bfe8a1','a81a664b','c24b8b70','c76c51a3','d192e819','d6990624','f40e3585','106aa070', ...
        '19a4c116','1e376c08','2748774c','34b0bcb5','391c0cb3','4ed8aa4a','5b9cca4f','682e6ff3', ...
        '748f82ee','78a5636f','84c87814','8cc70208','90befffa','a4506ceb','bef9a3f7','c67178f2'})]';
    H = hex2dec({'6a09e667','bb67ae85','3c6ef372','a54ff53a','510e527f','9b05688c','1f83d9ab','5be0cd19'})';
    n = numel(m);
    bits = n * 8;
    pad = mod(55 - n, 64);
    len = zeros(1, 8);
    for k = 8:-1:1                               % 64-bit big-endian bit length
        len(k) = mod(bits, 256);
        bits = floor(bits / 256);
    end
    m = [m, 128, zeros(1, pad), len];
    T = 2^32;
    words = reshape(m, 4, []);
    words = words(1, :) * 2^24 + words(2, :) * 2^16 + words(3, :) * 2^8 + words(4, :);
    W = zeros(1, 64);
    for b = 1:numel(words) / 16
        W(1:16) = words((b - 1) * 16 + (1:16));
        for t = 17:64
            x = W(t - 15);
            y = W(t - 2);
            s0 = bitxor(bitxor(rotr(x, 7), rotr(x, 18)), floor(x / 8));
            s1 = bitxor(bitxor(rotr(y, 17), rotr(y, 19)), floor(y / 1024));
            W(t) = mod(W(t - 16) + s0 + W(t - 7) + s1, T);
        end
        a = H(1); bb = H(2); c = H(3); d = H(4); e = H(5); f = H(6); g = H(7); hh = H(8);
        for t = 1:64
            S1 = bitxor(bitxor(rotr(e, 6), rotr(e, 11)), rotr(e, 25));
            ch = bitxor(bitand(e, f), bitand(T - 1 - e, g));
            t1 = mod(hh + S1 + ch + K(t) + W(t), T);
            S0 = bitxor(bitxor(rotr(a, 2), rotr(a, 13)), rotr(a, 22));
            maj = bitxor(bitxor(bitand(a, bb), bitand(a, c)), bitand(bb, c));
            t2 = mod(S0 + maj, T);
            hh = g; g = f; f = e;
            e = mod(d + t1, T);
            d = c; c = bb; bb = a;
            a = mod(t1 + t2, T);
        end
        H = mod(H + [a, bb, c, d, e, f, g, hh], T);
    end
    h = lower(reshape(dec2hex(H, 8)', 1, []));
end

function y = rotr(x, n)
    p = 2^n;
    lo = mod(x, p);
    y = (x - lo) / p + lo * 2^(32 - n);
end
