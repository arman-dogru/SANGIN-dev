function cp = utf8_codepoints(bytes)
%UTF8_CODEPOINTS Code points (double row) of valid UTF-8 BYTES.
%   CP = panama_uav.util.utf8_codepoints(BYTES) assumes BYTES has passed
%   panama_uav.util.decode_utf8 (which raises Python's errors for invalid
%   input) and decodes it vectorized.
    b = double(reshape(bytes, 1, []));
    lead = find(b < 128 | b >= 192);
    cp = zeros(1, numel(lead));
    one = b(lead) < 128;
    cp(one) = b(lead(one));
    two = b(lead) >= 192 & b(lead) < 224;
    i = lead(two);
    cp(two) = (b(i) - 192) * 64 + (b(i + 1) - 128);
    three = b(lead) >= 224 & b(lead) < 240;
    i = lead(three);
    cp(three) = (b(i) - 224) * 4096 + (b(i + 1) - 128) * 64 + (b(i + 2) - 128);
    four = b(lead) >= 240;
    i = lead(four);
    cp(four) = (b(i) - 240) * 262144 + (b(i + 1) - 128) * 4096 + (b(i + 2) - 128) * 64 + (b(i + 3) - 128);
end
