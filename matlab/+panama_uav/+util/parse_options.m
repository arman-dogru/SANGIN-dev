function opts = parse_options(opts, args, context)
%PARSE_OPTIONS Overlay name-value pairs on a defaults struct; unknown names error.
%   opts = panama_uav.util.parse_options(defaults, varargin, 'reset')
    if mod(numel(args), 2) ~= 0
        error('panama_uav:options', '%s: name-value arguments must come in pairs', context);
    end
    for k = 1:2:numel(args)
        name = args{k};
        if ~ischar(name) || ~isfield(opts, name)
            if ~ischar(name), name = class(name); end
            error('panama_uav:options', '%s: unknown option "%s"', context, name);
        end
        opts.(name) = args{k + 1};
    end
end
