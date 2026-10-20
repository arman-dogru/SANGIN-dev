classdef RecordsTest < matlab.unittest.TestCase
    % Parity: records.sha256 vs hashlib (make_fixtures.py:group_records),
    % with the built-in digest and with the portable implementation.
    methods (Test)
        function testFilesMatchHashlib(tc)
            fx = load_fixture('records');
            files = as_cell(fx.files);
            tc.verifyEqual(numel(files), 3);
            for k = 1:numel(files)
                path = fullfile(repo_root(), files{k}.path);
                tc.verifyEqual(panama_uav.records.sha256(path), files{k}.sha256, files{k}.path);
            end
            tc.verifyError(@() panama_uav.records.sha256(fullfile(repo_root(), 'no_such_file')), ...
                'panama_uav:records');
        end
        function testPortableMatchesHashlib(tc)
            % 14 lengths around the padding boundaries (55/56 bytes leave no
            % room for the length in the last block), on both code paths.
            fx = load_fixture('records');
            patterns = as_cell(fx.patterns);
            tc.verifyEqual(numel(patterns), 14);
            for k = 1:numel(patterns)
                n = patterns{k}.n;
                bytes = uint8(mod(7 * (0:n - 1) + 3, 256));
                label = sprintf('%d bytes', n);
                tc.verifyEqual(panama_uav.util.sha256_bytes(bytes, 'portable'), patterns{k}.sha256, ...
                    [label, ' portable']);
                tc.verifyEqual(panama_uav.util.sha256_bytes(bytes), patterns{k}.sha256, [label, ' built-in']);
            end
            % FIPS 180-4 examples: "abc" and the 448-bit two-block message.
            tc.verifyEqual(panama_uav.util.sha256_bytes(uint8('abc'), 'portable'), ...
                'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
            tc.verifyEqual(panama_uav.util.sha256_bytes( ...
                uint8('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'), 'portable'), ...
                '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
            tc.verifyError(@() panama_uav.util.sha256_bytes(uint8(1), 'md5'), 'panama_uav:records');
        end
    end
end
