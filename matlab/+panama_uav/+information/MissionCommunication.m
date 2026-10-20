classdef MissionCommunication < handle
    %MISSIONCOMMUNICATION Receiver information and mission routes
    %   (src/panama_uav/information.py:MissionCommunication).
    %
    %   Agents are the struct array kept by ExperimentEnvironment (fields id,
    %   position, goal, path, distance_to_goal, priority, ever_reached_goal).
    %   Python dicts keyed by agent id become cells indexed by id + 1.
    %   Field caches: caches{id+1}.task / .intentions / .priorities.
    %   Payloads keep this MATLAB layout; their wire sizes are those of the
    %   Python payloads (panama_uav.information.mission_wire), so the
    %   physical profile times them as Python does.
    properties
        config
        transport
        grid
        pathfinder
        goals
        reports = {}
        report_timestamps = zeros(1, 0)
        caches = {}
        sequence = 0
        decision = []
        position_history = {}   % {id+1} = [time row col] rows
    end
    properties (Constant)
        FIELDS = {'task', 'intentions', 'priorities'}
    end
    methods
        function obj = MissionCommunication(config, grid, agents, pathfinder, seed, cap, windows)
            if nargin < 7
                windows = [];
            end
            obj.config = config;
            obj.transport = panama_uav.transport.Transport(config);
            obj.transport.schedule_episode(seed, numel(agents), cap, windows);
            obj.grid = grid;
            obj.pathfinder = pathfinder;
            n = numel(agents);
            obj.goals = reshape([agents.goal], 2, [])';
            obj.reports = cell(1, n);
            obj.report_timestamps = zeros(1, n);
            obj.caches = cell(1, n);
            obj.position_history = cell(1, n);
            for k = 1:n
                obj.caches{k} = struct('task', panama_uav.information.InformationCache(), ...
                    'intentions', panama_uav.information.InformationCache(), ...
                    'priorities', panama_uav.information.InformationCache());
                obj.position_history{k} = [0.0, agents(k).position];
            end
            for k = 1:n
                obj.reports{k} = obj.report(agents(k));
                obj.report_timestamps(k) = 0.0;
            end
            for k = 1:n
                for f = 1:3
                    key = obj.FIELDS{f};
                    obj.caches{k}.(key).accept(0.0, obj.value(key, k - 1, obj.reports), 0);
                end
            end
        end

        function r = report(~, a)
            r = struct('position', a.position, 'goal', a.goal, 'path', a.path, ...
                'distance', a.distance_to_goal, 'priority', a.priority, ...
                'completed', a.ever_reached_goal);
        end

        function v = value(~, key, receiver, reports)
            switch key
                case 'task'
                    r = reports{receiver + 1};
                    v = panama_uav.information.Guidance(r.path, r.distance);
                case 'intentions'
                    v = cell(1, numel(reports));
                    for k = 1:numel(reports)
                        p = reports{k}.path;
                        v{k} = struct('path', p(1:min(6, size(p, 1)), :), ...
                            'completed', reports{k}.completed);
                    end
                otherwise
                    v = cellfun(@(r) r.priority, reports);
            end
        end

        function receive(obj, packet)
            payload = packet.payload;
            k = packet.agent + 1;
            switch packet.kind
                case 'report'
                    if packet.generated_at < obj.report_timestamps(k)
                        return;
                    end
                    path = obj.pathfinder(obj.grid, payload.position, payload.goal);
                    payload.path = path;
                    payload.distance = path_distance(path);
                    obj.reports{k} = payload;
                    obj.report_timestamps(k) = packet.generated_at;
                case 'mission_request'
                    reports = obj.reports;
                    reports{k} = payload.report;
                    sources = obj.report_timestamps;
                    sources(k) = packet.generated_at;
                    route = {sprintf('process:%.17g', obj.config.edge_processing_seconds)};
                    if strcmp(obj.config.mission_route, 'cloud')
                        route = {'satellite_up', sprintf('process:%.17g', obj.config.cloud_processing_seconds)};
                    end
                    obj.send(packet.agent, 'mission_compute', ...
                        struct('field', payload.field, 'reports', {reports}, 'sources', sources), ...
                        'route', route, 'generated_at', packet.generated_at, ...
                        'version', packet.version, 'delayed', false);
                case 'mission_compute'
                    field = payload.field;
                    reports = payload.reports;
                    r = reports{k};
                    path = obj.pathfinder(obj.grid, r.position, r.goal);
                    r.path = path;
                    r.distance = path_distance(path);
                    reports{k} = r;
                    if strcmp(obj.config.mission_route, 'uav')
                        route = {'access_down'};
                    else
                        route = {'satellite_down', 'access_down'};
                    end
                    if strcmp(field, 'task')
                        ids = packet.agent;
                        times = packet.generated_at;
                    else
                        ids = 0:numel(payload.sources) - 1;
                        times = payload.sources;
                    end
                    item = struct('field', field, 'value', {obj.value(field, packet.agent, reports)}, ...
                        'source_ids', ids, 'source_times', times);
                    obj.send(packet.agent, 'information', item, 'route', route, ...
                        'generated_at', packet.generated_at, 'version', packet.version, 'delayed', true);
                case 'information'
                    cache = obj.caches{k}.(payload.field);
                    accepted = cache.accept(packet.generated_at, payload.value, packet.version, ...
                        payload.source_ids, payload.source_times);
                    if accepted && strcmp(payload.field, 'task')
                        h = obj.position_history{k};
                        for j = 1:size(h, 1)
                            if packet.generated_at <= h(j, 1) && h(j, 1) <= obj.transport.now
                                payload.value.consume(h(j, 2:3));
                            end
                        end
                    end
            end
        end

        function update(obj, agents, now)
            t = obj.transport;
            obj.decision = [];
            receiver = @(p) obj.receive(p);
            for k = 1:numel(agents)
                obj.position_history{k}(end + 1, :) = [now, agents(k).position];
            end
            t.advance(now, receiver);
            for k = 1:numel(agents)
                obj.send(agents(k).id, 'report', obj.report(agents(k)), 'route', {'access_up'}, ...
                    'delayed', false, 'version', obj.sequence);
            end
            t.advance(now, receiver);
            obj.sequence = obj.sequence + 1;
            fresh = arrayfun(@(a) obj.report(a), agents, 'UniformOutput', false);
            ids = [agents.id];
            for k = 1:numel(agents)
                for f = 1:3
                    key = obj.FIELDS{f};
                    if ~any(strcmp(key, obj.config.stale_information)) || strcmp(obj.config.profile, 'perfect')
                        obj.caches{k}.(key).accept(now, obj.value(key, agents(k).id, fresh), ...
                            obj.sequence, ids, now * ones(size(ids)));
                        continue;
                    end
                    obj.send(agents(k).id, 'mission_request', ...
                        struct('field', key, 'report', obj.report(agents(k))), ...
                        'route', {'access_up'}, 'version', obj.sequence, 'delayed', false);
                end
            end
            t.advance(now, receiver);
            for k = 1:numel(agents)
                obj.caches{k}.task.value.consume(agents(k).position);
            end
        end

        function prepare_decision(obj, agents, cycle_start, deadline_seconds) %#ok<INUSD>
            error('panama_uav:notImplemented', ...
                'MissionCommunication.prepare_decision (information.py) is milestone M4 (decision deadline)');
        end

        function send(obj, agent, kind, payload, varargin)
            %SEND Transport.send with the wire size of the payload that
            %   Python sends (panama_uav.information.mission_wire), so that
            %   every profile, the physical one included, logs and times
            %   Python's byte counts.
            bytes = panama_uav.transport.encode_size(panama_uav.information.mission_wire(kind, payload));
            obj.transport.send(agent, kind, payload, varargin{:}, 'wire_bytes', bytes);
        end

        function [path, distance, intentions, priorities] = observation_values(obj, agent)
            c = obj.caches{agent.id + 1};
            path = c.task.value.consume(agent.position);
            distance = c.task.value.reported_distance;
            intentions = c.intentions.value;
            priorities = c.priorities.value;
        end

        function a = ages(obj)
            %AGES N-by-3 information ages [task intentions priorities].
            a = zeros(numel(obj.caches), 3);
            for k = 1:numel(obj.caches)
                for f = 1:3
                    a(k, f) = obj.caches{k}.(obj.FIELDS{f}).age(obj.transport.now);
                end
            end
        end

        function s = snapshot(obj)
            n = numel(obj.caches);
            guidance = cell(1, n);
            for k = 1:n
                guidance{k} = obj.caches{k}.task.value.route;
            end
            s = struct('time', obj.transport.now, 'decision', obj.decision, ...
                'information_age', obj.ages(), 'cached_guidance', {guidance}, ...
                'uav_report_positions', reshape(cell2mat(cellfun(@(r) r.position, obj.reports, ...
                'UniformOutput', false)), 2, [])', ...
                'uav_report_age_seconds', obj.transport.now - obj.report_timestamps);
        end
    end
end

function d = path_distance(path)
    if isempty(path)
        d = inf;
    else
        d = size(path, 1) - 1;
    end
end
