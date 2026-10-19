classdef Transport < handle
    %TRANSPORT Deterministic virtual-time transport (src/panama_uav/transport.py:Transport).
    %
    %   Ported in M1: the 'perfect' and 'controlled' profiles, seeded
    %   reservation windows (injectable), reservation exposure, FIFO flow
    %   buffering, processing hops, delivery, logs and message counters.
    %   Not yet ported (M1b): the 'physical' profile (link service,
    %   satellite handovers, imported delay traces, orbital timelines) and
    %   pickle-exact byte accounting; those raise panama_uav:notImplemented.
    properties
        config
        now = 0.0
        sequence = 0
        message_sequence = 0
        calendar
        windows = {}        % windows{agent+1} = K-by-2 [start end] seconds
        flow_keys = {}      % 'agent|kind'
        flow_ready = zeros(0, 1)
        log = {}            % cell of structs (event, time, ...)
        counters
    end
    methods
        function obj = Transport(config)
            if strcmp(config.profile, 'physical')
                error('panama_uav:notImplemented', ...
                    'Transport physical profile (transport.py:Transport._start/_finish_transmission) is milestone M1b');
            end
            obj.config = config;
            obj.calendar = panama_uav.transport.EventCalendar();
            obj.counters = struct('messages_generated', 0, 'messages_delivered', 0, ...
                'exposed_messages', 0);
        end
        function schedule_episode(obj, seed, agents, cap, windows)
            %SCHEDULE_EPISODE Reservation windows (Transport.schedule_episode).
            %   WINDOWS, when given, is a cell (one per agent) of K-by-2 window
            %   [start end] times recorded from NumPy; otherwise MATLAB's RNG
            %   draws them with the same distributions (statistical parity).
            if nargin < 4 || isempty(cap)
                cap = 250;
            end
            obj.windows = cell(1, agents);
            if ~obj.config.contention_enabled
                obj.windows = {};
                return;
            end
            c = obj.config;
            for agent = 0:agents - 1
                if nargin >= 5 && ~isempty(windows)
                    w = reshape(double(windows{agent + 1}), [], 2);
                else
                    base = seed * 1000 + 2 * agent;
                    count = c.windows_min - 1 + panama_uav.util.seeded_randperm(base, ...
                        c.windows_max - c.windows_min + 1, 1);
                    starts = sort(panama_uav.util.seeded_randperm(base + 1, cap - 1, count));
                    w = [obj.now + starts' * c.seconds_per_step, ...
                        obj.now + (starts' + c.reservation_steps) * c.seconds_per_step];
                end
                obj.windows{agent + 1} = w;
                for k = 1:size(w, 1)
                    obj.add_log(struct('event', 'scheduled_reservation', 'time', obj.now, ...
                        'agent', agent, 'start', w(k, 1), 'end', w(k, 2), 'seed', seed));
                end
            end
        end
        function id = send(obj, agent, kind, payload, varargin)
            %SEND Queue a message (Transport.send). Options: 'route' (cellstr),
            %   'generated_at', 'version', 'delayed' (default true).
            opts = struct('route', {{}}, 'generated_at', [], 'version', 0, 'delayed', true);
            for k = 1:2:numel(varargin)
                opts.(varargin{k}) = varargin{k + 1};
            end
            obj.message_sequence = obj.message_sequence + 1;
            if isempty(opts.generated_at)
                generated = obj.now;
            else
                generated = opts.generated_at;
            end
            packet = struct('id', obj.message_sequence, 'agent', agent, 'kind', kind, ...
                'generated_at', generated, 'version', opts.version, 'route', {opts.route}, ...
                'payload', {payload});
            obj.counters.messages_generated = obj.counters.messages_generated + 1;
            obj.add_log(struct('event', 'generated', 'time', obj.now, 'id', packet.id, ...
                'agent', agent, 'kind', kind, 'version', opts.version, 'source_time', generated));
            release = obj.now;
            c = obj.config;
            if opts.delayed && ~strcmp(c.profile, 'perfect') && c.contention_enabled ...
                    && agent + 1 <= numel(obj.windows)
                w = obj.windows{agent + 1};
                for k = 1:size(w, 1)
                    if w(k, 1) <= obj.now && obj.now < w(k, 2)
                        release = release + c.delay_steps * c.seconds_per_step;
                        obj.counters.exposed_messages = obj.counters.exposed_messages + 1;
                        obj.add_log(struct('event', 'reservation_exposure', 'time', obj.now, ...
                            'agent', agent, 'id', packet.id, 'start', w(k, 1), 'end', w(k, 2), ...
                            'release', release));
                        break;
                    end
                end
            end
            if opts.delayed && ~strcmp(c.profile, 'perfect')
                key = sprintf('%d|%s', agent, kind);
                j = find(strcmp(obj.flow_keys, key), 1);
                if isempty(j)
                    previous = obj.now;
                    obj.flow_keys{end + 1} = key;
                    j = numel(obj.flow_keys);
                else
                    previous = obj.flow_ready(j);
                end
                release = max(release, previous);
                obj.flow_ready(j) = release;
                if release > obj.now
                    obj.add_log(struct('event', 'buffered', 'time', obj.now, 'agent', agent, ...
                        'id', packet.id, 'ready_at', release, 'buffer_seconds', release - obj.now));
                end
            end
            obj.event(release, 'enqueue', {packet, 0});
            id = packet.id;
        end
        function delivered = advance(obj, until_time, receiver)
            %ADVANCE Process events up to UNTIL (Transport.advance). RECEIVER is
            %   a function handle called with each delivered packet struct.
            if until_time < obj.now - 1e-12
                error('panama_uav:transport', 'Transport time cannot reverse');
            end
            delivered = {};
            obj.event(until_time, 'clock', []);
            while obj.calendar.peek() <= until_time + 1e-12
                [at, ~, kind, value] = obj.calendar.pop();
                obj.now = at;
                if strcmp(kind, 'clock')
                    continue;
                end
                packet = value{1};
                hop = value{2};
                if hop == numel(packet.route)
                    obj.counters.messages_delivered = obj.counters.messages_delivered + 1;
                    obj.add_log(struct('event', 'delivered', 'time', at, 'id', packet.id, ...
                        'agent', packet.agent, 'kind', packet.kind, 'source_time', packet.generated_at, ...
                        'age_seconds', at - packet.generated_at, 'version', packet.version));
                    delivered{end + 1} = packet; %#ok<AGROW>
                    if nargin >= 3 && ~isempty(receiver)
                        receiver(packet);
                    end
                    continue;
                end
                name = packet.route{hop + 1};
                if startsWith(name, 'process:')
                    obj.event(at + str2double(name(9:end)), 'enqueue', {packet, hop + 1});
                else
                    obj.event(at, 'enqueue', {packet, hop + 1});
                end
            end
            obj.now = double(until_time);
        end
        function w = handover_windows(obj, start, finish) %#ok<INUSD>
            %HANDOVER_WINDOWS Empty outside the physical profile (Transport.handover_windows).
            w = zeros(0, 2);
        end
        function occupancy(obj) %#ok<MANU>
            error('panama_uav:notImplemented', ...
                'Transport.occupancy needs pickle-exact byte sizes (transport.py:encode); milestone M1b');
        end
    end
    methods (Access = private)
        function event(obj, at, kind, value)
            obj.sequence = obj.sequence + 1;
            obj.calendar.schedule(double(at), kind, value);
        end
        function add_log(obj, entry)
            obj.log{end + 1} = entry;
        end
    end
end
