function v = py_value(spec)
%PY_VALUE MATLAB value standing for a Python value described by
%   make_fixtures.py:py_spec (see panama_uav.transport.encode_size for the
%   mapping). Strings arrive as UTF-8 hex, ints as 8 little-endian bytes,
%   floats as IEEE hex bits; repeat_* specs expand a long list, str or dict;
%   tuple_rows is a list of int tuples (int64 items) and object a dataclass
%   instance (PyInstance). A dict whose keys are all str is a struct, any
%   other dict a PyDict.
    switch spec.t
        case 'none'
            v = [];
        case 'bool'
            v = logical(spec.v);
        case 'int'
            raw = uint8(hex2dec(reshape(spec.le, 2, [])'))';
            if spec.unsigned
                v = typecast(raw, 'uint64');
            else
                v = typecast(raw, 'int64');
            end
        case 'float'
            v = panama_uav.util.hex_to_double(spec.hex);
        case 'str'
            v = utf8_text(spec.hex);
        case 'bytes'
            v = panama_uav.transport.PyBytes(spec.n);
        case 'list'
            v = cellfun(@py_value, as_cell(spec.items), 'UniformOutput', false);
            if isempty(v)
                v = {};
            end
        case 'tuple'
            items = cellfun(@py_value, as_cell(spec.items), 'UniformOutput', false);
            v = panama_uav.transport.PyTuple(items{:});
        case 'dict'
            keys = as_cell(spec.keys);
            values = as_cell(spec.values);
            if all(cellfun(@(k) strcmp(k.t, 'str'), keys))
                v = struct();
                for k = 1:numel(keys)
                    v.(py_value(keys{k})) = py_value(values{k});
                end
            else
                % int (agent id), float, bool, None or tuple keys
                v = panama_uav.transport.PyDict(cellfun(@py_value, keys, 'UniformOutput', false), ...
                    cellfun(@py_value, values, 'UniformOutput', false));
            end
        case 'tuple_rows'
            % A list of int tuples, as the generic cell of PyTuple(int64...);
            % EncodeTest also sizes it as PyTupleRows (tuple_rows_matrix).
            m = tuple_rows_matrix(spec);
            v = cell(1, size(m, 1));
            for k = 1:size(m, 1)
                row = num2cell(m(k, :));
                v{k} = panama_uav.transport.PyTuple(row{:});
            end
        case 'object'
            v = panama_uav.transport.PyInstance(spec.module, spec.qualname, py_value(spec.state));
        case 'repeat_list'
            item = py_value(spec.item);
            v = repmat({item}, 1, spec.n);
        case 'repeat_str'
            v = repmat(utf8_text(spec.item), 1, spec.n);
        case 'repeat_dict'
            item = py_value(spec.item);
            names = arrayfun(@(i) sprintf('k%d', i), 0:spec.n - 1, 'UniformOutput', false);
            v = cell2struct(repmat({item}, spec.n, 1), names(:), 1);
        otherwise
            error('py_value: unknown spec type %s', spec.t);
    end
end

function s = utf8_text(h)
    if isempty(h)
        s = '';
    else
        s = panama_uav.util.decode_utf8(uint8(hex2dec(reshape(h, 2, [])'))');
    end
end
