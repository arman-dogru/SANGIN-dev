function s = py_float_repr(x)
%PY_FLOAT_REPR Python's repr(float(X)) (also what json.dumps writes).
%   The shortest decimal string that reads back as X (David Gay's
%   algorithm in CPython, here found by trying 1 to 17 significant digits),
%   in fixed notation when the decimal exponent is in [-4, 16) and in
%   exponent notation otherwise: 0.1, 1.0, 1e-05, 1.5e+16, 'inf', 'nan',
%   -0.0. The digits come from sprintf('%.*e'), which is correctly rounded
%   in glibc and MATLAB.
    if isnan(x)
        s = 'nan';
        return;
    elseif isinf(x)
        if x > 0, s = 'inf'; else, s = '-inf'; end
        return;
    end
    sign = '';
    if x < 0 || (x == 0 && 1 / x < 0)
        sign = '-';
    end
    a = abs(x);
    if a == 0
        s = [sign, '0.0'];
        return;
    end
    for p = 1:17
        t = sprintf('%.*e', p - 1, a);
        if str2double(t) == a
            break;
        end
    end
    k = strfind(t, 'e');
    mant = strrep(t(1:k - 1), '.', '');
    e = str2double(t(k + 1:end));
    mant = regexprep(mant, '0+$', '');
    if isempty(mant)
        mant = '0';
    end
    if e >= -4 && e < 16
        if e >= 0
            if numel(mant) <= e + 1
                s = [mant, repmat('0', 1, e + 1 - numel(mant)), '.0'];
            else
                s = [mant(1:e + 1), '.', mant(e + 2:end)];
            end
        else
            s = ['0.', repmat('0', 1, -e - 1), mant];
        end
    else
        s = mant(1);
        if numel(mant) > 1
            s = [s, '.', mant(2:end)];
        end
        if e < 0
            s = sprintf('%se-%02d', s, -e);
        else
            s = sprintf('%se+%02d', s, e);
        end
    end
    s = [sign, s];
end
