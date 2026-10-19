function c = with_communication(c, varargin)
%WITH_COMMUNICATION Copy of config C with communication options replaced.
%   Equivalent of dataclasses.replace(c, communication=replace(..., **kw)),
%   including TransportConfig validation. Usage:
%   c = panama_uav.config.with_communication(c, 'delay_steps', 10, ...)
    t = c.communication;
    for k = 1:2:numel(varargin)
        if ~isfield(t, varargin{k})
            error('panama_uav:config', 'Unknown communication option "%s"', varargin{k});
        end
        t.(varargin{k}) = varargin{k + 1};
    end
    panama_uav.config.validate_transport(t);
    c.communication = t;
end
