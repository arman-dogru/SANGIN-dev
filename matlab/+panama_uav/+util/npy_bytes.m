function bytes = npy_bytes(kind, data, width)
%NPY_BYTES The bytes np.save writes for a 1-D float64 or str array.
%   B = panama_uav.util.npy_bytes('f8', X) is a '<f8' array of shape
%   (numel(X),). B = panama_uav.util.npy_bytes('U', C, W) is a '<U<W>'
%   array of shape (numel(C),) from the cell C of code-point rows, each
%   UTF-32LE and NUL-padded to W code points (W defaults to the longest,
%   at least 1, as np.array(list_of_str) chooses). With C a code-point row
%   instead of a cell, the array is 0-d (shape ()), as np.savez stores a
%   Python str. Format version 1.0 with NumPy's header layout: the dict
%   text, 21 - len(repr(shape[0])) spaces of room for growing the first
%   axis (1-D and up only), then spaces up to a multiple of 64 bytes and a
%   newline.
    switch kind
        case 'f8'
            x = double(reshape(data, 1, []));
            descr = '<f8';
            shape = sprintf('(%d,)', numel(x));
            growth = 21 - numel(sprintf('%d', numel(x)));
            body = typecast(x, 'uint8');
            if little_endian_host() == false
                body = reshape(flipud(reshape(body, 8, [])), 1, []);
            end
        case 'U'
            scalar = ~iscell(data);
            if scalar
                data = {data};
            end
            lengths = reshape(cellfun('length', data), 1, []);
            if nargin < 3
                width = max([1, lengths]);
            end
            if any(lengths > width)
                error('panama_uav:npy', 'npy_bytes: a string is longer than the array width %d', width);
            end
            descr = sprintf('<U%d', width);
            % Column k holds string k, NUL-padded: one indexed assignment.
            if any(cellfun('isclass', data, 'char'))
                data = cellfun(@double, data, 'UniformOutput', false);
            end
            if any(cellfun('size', data, 1) > 1)
                data = cellfun(@(c) reshape(c, 1, []), data, 'UniformOutput', false);
            end
            flat = double([data{:}]);
            units = zeros(width, numel(data));
            column = repelem(0:numel(data) - 1, lengths);
            within = (1:sum(lengths)) - repelem(cumsum([0, lengths(1:end - 1)]), lengths);
            units(column * width + within) = flat;
            w = units(:)';
            body = uint8(reshape([mod(w, 256); mod(floor(w / 256), 256); ...
                mod(floor(w / 65536), 256); floor(w / 16777216)], 1, []));
            if scalar
                shape = '()';
                growth = 0;
            else
                shape = sprintf('(%d,)', numel(data));
                growth = 21 - numel(sprintf('%d', numel(data)));
            end
        otherwise
            error('panama_uav:npy', 'npy_bytes: kind must be ''f8'' or ''U''');
    end
    header = [sprintf('{''descr'': ''%s'', ''fortran_order'': False, ''shape'': %s, }', descr, shape), ...
        repmat(' ', 1, growth)];
    hlen = numel(header) + 1;
    pad = 64 - mod(10 + hlen, 64);
    header = [header, repmat(' ', 1, pad), newline];
    if numel(header) > 65535
        error('panama_uav:npy', 'npy_bytes: header too long for format 1.0');
    end
    n = numel(header);
    bytes = [uint8([147, double('NUMPY'), 1, 0, mod(n, 256), floor(n / 256)]), uint8(double(header)), ...
        reshape(uint8(body), 1, [])];
end

function tf = little_endian_host()
    [~, ~, e] = computer();
    tf = strcmp(e, 'L');
end
