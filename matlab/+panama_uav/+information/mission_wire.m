function w = mission_wire(kind, payload)
%MISSION_WIRE The Python value that MissionCommunication sends, for encode_size.
%   W = panama_uav.information.mission_wire(KIND, PAYLOAD) maps the MATLAB
%   payload of a 'report', 'mission_request', 'mission_compute' or
%   'information' message onto the typed values of
%   panama_uav.transport.encode_size, shaped as information.py builds the
%   payload, so that encode_size(W) is len(transport.encode(payload)):
%
%     report           {"position": (r, c), "goal": (r, c), "path": [(r, c), ...],
%                       "distance": float, "priority": float, "completed": bool}
%     mission_request  {"field": str, "report": report}
%     mission_compute  {"field": str, "reports": {agent: report},
%                       "sources": {agent: float}}
%     information      {field: {"value": value, "sources": {agent: float}}}
%                      with value Guidance(route=[(r, c), ...],
%                      reported_distance=float) for "task",
%                      {agent: {"path": [(r, c), ...], "completed": bool}}
%                      for "intentions" and {agent: float} for "priorities".
%
%   Agent ids are Python ints (int64 keys, in id order, as the Python dicts
%   are built from self.reports and self.report_timestamps), cell
%   coordinates are Python ints, and distances, priorities and times are
%   floats. All of these are builtins in Python: no NumPy scalar reaches the
%   payloads (measured over physical-profile rollouts by make_fixtures.py).
    switch kind
        case 'report'
            w = report_wire(payload);
        case 'mission_request'
            w = struct('field', payload.field, 'report', report_wire(payload.report));
        case 'mission_compute'
            n = numel(payload.reports);
            ids = num2cell(int64(0:n - 1));
            w = struct('field', payload.field, ...
                'reports', panama_uav.transport.PyDict(ids, cellfun(@report_wire, payload.reports, ...
                'UniformOutput', false)), ...
                'sources', float_dict(0:numel(payload.sources) - 1, payload.sources));
        case 'information'
            item = struct('value', {value_wire(payload.field, payload.value)}, ...
                'sources', float_dict(payload.source_ids, payload.source_times));
            w = struct(payload.field, item);
        otherwise
            error('panama_uav:encode', 'mission_wire: unknown message kind %s', kind);
    end
end

function w = report_wire(r)
    w = struct('position', int_tuple(r.position), 'goal', int_tuple(r.goal), ...
        'path', panama_uav.transport.PyTupleRows(reshape(r.path, [], 2)), ...
        'distance', double(r.distance), 'priority', double(r.priority), ...
        'completed', logical(r.completed));
end

function w = value_wire(field, v)
    switch field
        case 'task'
            w = panama_uav.transport.PyInstance('panama_uav.information', 'Guidance', ...
                struct('route', panama_uav.transport.PyTupleRows(v.route), ...
                'reported_distance', double(v.reported_distance)));
        case 'intentions'
            values = cellfun(@(x) struct('path', panama_uav.transport.PyTupleRows(reshape(x.path, [], 2)), ...
                'completed', logical(x.completed)), v, 'UniformOutput', false);
            w = panama_uav.transport.PyDict(num2cell(int64(0:numel(v) - 1)), values);
        case 'priorities'
            w = float_dict(0:numel(v) - 1, v);
        otherwise
            error('panama_uav:encode', 'mission_wire: unknown information field %s', field);
    end
end

function d = float_dict(ids, values)
    d = panama_uav.transport.PyDict(num2cell(int64(ids)), num2cell(double(values)));
end

function t = int_tuple(p)
    t = panama_uav.transport.PyTuple(int64(p(1)), int64(p(2)));
end
