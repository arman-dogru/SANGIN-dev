function x = fixture_number(x)
%FIXTURE_NUMBER Convert JSON fixture numbers, where "inf"/"-inf"/"nan" are strings.
    if ischar(x)
        switch x
            case 'inf', x = Inf;
            case '-inf', x = -Inf;
            case 'nan', x = NaN;
            otherwise
                error('panama_uav:fixture', 'Unexpected numeric string %s', x);
        end
    elseif iscell(x)
        x = cellfun(@panama_uav.util.fixture_number, x);
    end
end
