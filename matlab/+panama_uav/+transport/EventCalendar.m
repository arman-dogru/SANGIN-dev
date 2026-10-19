classdef EventCalendar < handle
    %EVENTCALENDAR Minimal discrete-event calendar replacing SimPy
    %   (src/panama_uav/event_calendar.py:EventCalendar).
    %
    %   Events are ordered by (time, insertion id) like SimPy's heap of
    %   Timeout events with equal priority. As in SimPy, the ordering time
    %   is env_now + max(0, at - env_now), while pop returns the requested
    %   time AT; both are kept so float rounding matches Python exactly.
    properties
        now = 0.0          % SimPy environment.now
        sequence = 0       % token counter (EventCalendar.sequence)
        eid = 0            % SimPy event id counter
        keys = zeros(0, 1) % ordering times
        ids = zeros(0, 1)  % SimPy eids (tie-break)
        tokens = zeros(0, 1)
        records = cell(0, 1) % {at, token, kind, value}
    end
    methods
        function schedule(obj, at, kind, value)
            if at < obj.now - 1e-10
                error('panama_uav:calendar', 'Event cannot be scheduled in the past');
            end
            obj.sequence = obj.sequence + 1;
            obj.eid = obj.eid + 1;
            % Linear indexing on column vectors; (end+1, 1) misbehaves on a
            % 1-by-0 cell left by deletion in Octave.
            n = numel(obj.keys) + 1;
            obj.keys(n, 1) = obj.now + max(0.0, at - obj.now);
            obj.ids(n, 1) = obj.eid;
            obj.tokens(n, 1) = obj.sequence;
            obj.records{n, 1} = {double(at), obj.sequence, kind, value};
        end
        function t = peek(obj)
            if isempty(obj.keys)
                t = inf;
            else
                t = min(obj.keys);
            end
        end
        function [at, token, kind, value] = pop(obj)
            if isempty(obj.keys)
                error('panama_uav:calendar', 'No scheduled events');
            end
            t = min(obj.keys);
            candidates = find(obj.keys == t);
            [~, j] = min(obj.ids(candidates));
            k = candidates(j);
            obj.now = obj.keys(k);
            r = obj.records{k};
            obj.keys(k) = [];
            obj.ids(k) = [];
            obj.tokens(k) = [];
            obj.records(k) = [];
            obj.records = reshape(obj.records, [], 1);
            [at, token, kind, value] = r{:};
        end
        function n = count(obj)
            n = numel(obj.keys);
        end
        function r = pending(obj)
            %PENDING Pending records ordered by token, like EventCalendar.records().
            [~, order] = sort(obj.tokens);
            r = obj.records(order);
        end
    end
end
