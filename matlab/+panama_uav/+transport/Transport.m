classdef Transport < handle
    %TRANSPORT Deterministic virtual-time transport (src/panama_uav/transport.py:Transport).
    %
    %   Profiles 'perfect', 'controlled' and 'physical'. Ported: seeded
    %   reservation windows (injectable), reservation exposure, FIFO flow
    %   buffering, processing hops, delivery, logs and counters (M1); the
    %   physical link service with shared capacity, per-agent round robin,
    %   packet fragmentation and overhead, periodic satellite handover
    %   pauses, propagation delay, imported uplink/downlink delay traces,
    %   byte counters, occupancy and handover windows (M1b).
    %   Not ported: orbital timelines (leo_timeline with the physical
    %   profile, OrbitTimeline, milestone M5), which raise
    %   panama_uav:notImplemented.
    %
    %   Wire sizes are panama_uav.transport.encode_size of the payload (or
    %   the 'wire_bytes' option, Python's wire=) plus the encoded envelope
    %   {agent, kind, timestamp, version}, as in Python. For payloads that
    %   encode_size does not cover yet (the mission payloads; M1b-2) the
    %   physical profile raises panama_uav:notImplemented and the other
    %   profiles, which never use sizes for timing, record NaN bytes.
    properties
        config
        now = 0.0
        sequence = 0
        message_sequence = 0
        next_handover_index = 1
        satellite_assignment = 0
        calendar
        links               % struct array: name, capacity_bps, busy, last_agent, agents, queues
        windows = {}        % windows{agent+1} = K-by-2 [start end] seconds
        flow_keys = {}      % 'agent|kind'
        flow_ready = zeros(0, 1)
        log = {}            % cell of structs (event, time, ...)
        counters
        traces = struct()   % satellite_up / satellite_down -> DelayTrace
    end
    properties (Constant)
        LINK_NAMES = {'access_up', 'access_down', 'satellite_up', 'satellite_down'}
    end
    methods
        function obj = Transport(config)
            obj.config = config;
            obj.calendar = panama_uav.transport.EventCalendar();
            capacities = [config.access_uplink_mbps, config.access_downlink_mbps, ...
                config.satellite_uplink_mbps, config.satellite_downlink_mbps];
            for k = 1:4
                obj.links(k).name = obj.LINK_NAMES{k};
                obj.links(k).capacity_bps = capacities(k) * 1e6;
                obj.links(k).busy = false;
                obj.links(k).last_agent = -1;
                obj.links(k).agents = zeros(1, 0);
                obj.links(k).queues = {};
            end
            obj.counters = struct('messages_generated', 0, 'bytes_generated', 0, ...
                'exposed_messages', 0, 'messages_delivered', 0, 'bytes_delivered', 0, ...
                'hop_bytes_transmitted', 0);
            if ~isempty(config.leo_timeline) && strcmp(config.profile, 'physical')
                error('panama_uav:notImplemented', ['Orbital timelines (transport.py with ', ...
                    'leo.OrbitTimeline) are milestone M5; unset leo_timeline']);
            end
            % Python loads and checks traces for every profile; only the
            % physical profile replays them.
            pairs = {'satellite_up', config.uplink_trace, 'uplink'; ...
                'satellite_down', config.downlink_trace, 'downlink'};
            for k = 1:2
                if ~isempty(pairs{k, 2})
                    trace = panama_uav.transport.DelayTrace.load(pairs{k, 2});
                    if ~isfield(trace.metadata, 'direction')
                        error('panama_uav:trace', '''direction''');   % Python: KeyError
                    end
                    if ~strcmp(trace.metadata.direction, pairs{k, 3})
                        error('panama_uav:trace', 'Trace direction mismatch');
                    end
                    obj.traces.(pairs{k, 1}) = trace;
                end
            end
        end
        function schedule_episode(obj, seed, agents, cap, windows)
            %SCHEDULE_EPISODE Reservation windows (Transport.schedule_episode).
            %   WINDOWS, when given, is a cell (one per agent) of K-by-2 window
            %   [start end] times recorded from NumPy. Otherwise a fresh
            %   panama_uav.util.Xorshift128(SEED) draws them for all agents in
            %   turn, like Python's np.random.default_rng(seed): count uniform
            %   on [windows_min, windows_max], distinct start steps uniform on
            %   1..cap-1. Same distribution as NumPy, different stream.
            if nargin < 4 || isempty(cap)
                cap = 250;
            end
            obj.windows = cell(1, agents);
            if ~obj.config.contention_enabled
                obj.windows = {};
                return;
            end
            c = obj.config;
            rng = [];
            if nargin < 5 || isempty(windows)
                rng = panama_uav.util.Xorshift128(seed);
            end
            for agent = 0:agents - 1
                if nargin >= 5 && ~isempty(windows)
                    w = reshape(double(windows{agent + 1}), [], 2);
                else
                    count = c.windows_min + rng.randint(c.windows_max - c.windows_min + 1);
                    starts = sort(rng.choice(cap - 1, count));
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
            %   'generated_at', 'version', 'delayed' (default true) and
            %   'wire_bytes' (size of an already encoded body; Python wire=).
            opts = panama_uav.util.parse_options(struct('route', {{}}, 'generated_at', [], ...
                'version', 0, 'delayed', true, 'wire_bytes', []), varargin, 'Transport.send');
            c = obj.config;
            if any(strcmp(kind, {'model', 'model_relay'})) && strcmp(c.profile, 'physical') ...
                    && any(cellfun(@(name) isfield(obj.traces, name), opts.route))
                error('panama_uav:transport', ['UDP packet-delay traces do not calibrate bulk ', ...
                    'model snapshots; use the orbital capacity model']);
            end
            obj.message_sequence = obj.message_sequence + 1;
            if isempty(opts.generated_at)
                generated = obj.now;
            else
                generated = opts.generated_at;
            end
            if ~isempty(opts.wire_bytes)
                body = double(opts.wire_bytes);
            else
                try
                    body = panama_uav.transport.encode_size(payload);
                catch err
                    if ~strcmp(err.identifier, 'panama_uav:notImplemented') || strcmp(c.profile, 'physical')
                        rethrow(err);
                    end
                    body = NaN;
                end
            end
            % The envelope is transmitted, too (transport.py:282).
            header = panama_uav.transport.encode_size(struct('agent', int64(agent), 'kind', kind, ...
                'timestamp', double(generated), 'version', int64(opts.version)));
            packet = struct('id', obj.message_sequence, 'agent', agent, 'kind', kind, ...
                'generated_at', generated, 'version', opts.version, 'route', {opts.route}, ...
                'payload', {payload}, 'size_bytes', body);
            obj.counters.messages_generated = obj.counters.messages_generated + 1;
            obj.counters.bytes_generated = obj.counters.bytes_generated + body + header;
            obj.add_log(struct('event', 'generated', 'time', obj.now, 'id', packet.id, ...
                'agent', agent, 'kind', kind, 'bytes', body + header, 'version', opts.version, ...
                'source_time', generated));
            release = obj.now;
            if opts.delayed && ~strcmp(c.profile, 'perfect') && c.contention_enabled ...
                    && agent >= 0 && agent + 1 <= numel(obj.windows)
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
            obj.event(release, 'enqueue', {packet, 0, header});
            id = packet.id;
        end
        function delivered = advance(obj, until_time, receiver)
            %ADVANCE Process events up to UNTIL (Transport.advance). RECEIVER is
            %   a function handle called with each delivered packet struct.
            if until_time < obj.now - 1e-12
                error('panama_uav:transport', 'Transport time cannot reverse');
            end
            delivered = {};
            c = obj.config;
            physical = strcmp(c.profile, 'physical');
            if physical && c.handover_enabled
                while obj.next_handover_index * c.handover_interval_seconds <= until_time
                    at = obj.next_handover_index * c.handover_interval_seconds;
                    obj.event(at, 'handover_start', obj.next_handover_index);
                    obj.event(at + c.handover_interruption_seconds, 'handover_end', obj.next_handover_index);
                    obj.next_handover_index = obj.next_handover_index + 1;
                end
            end
            obj.event(until_time, 'clock', []);
            while obj.calendar.peek() <= until_time + 1e-12
                [at, token, kind, value] = obj.calendar.pop(); %#ok<ASGLU> (Octave mis-handles ~ here)
                obj.now = at;
                switch kind
                    case 'clock'
                        continue;
                    case {'handover_start', 'handover_end'}
                        if strcmp(kind, 'handover_start')
                            obj.satellite_assignment = value;
                        end
                        names = {'satellite_up', 'satellite_down'};
                        affects = names(~cellfun(@(n) isfield(obj.traces, n), names));
                        obj.add_log(struct('event', kind, 'time', at, 'assignment', value, ...
                            'affects_links', {affects}));
                        continue;
                    case 'free'
                        if iscell(value)
                            name = value{1};
                            k = obj.link_index(name);
                            obj.push_front(k, value{2}.message.agent, {value{2}, value{3}});
                        else
                            name = value;
                            k = obj.link_index(name);
                        end
                        obj.links(k).busy = false;
                        obj.start(name);
                        continue;
                end
                packet = value{1};
                hop = value{2};
                header = value{3};
                if hop == numel(packet.route)
                    obj.counters.messages_delivered = obj.counters.messages_delivered + 1;
                    obj.counters.bytes_delivered = obj.counters.bytes_delivered + packet.size_bytes + header;
                    obj.add_log(struct('event', 'delivered', 'time', at, 'id', packet.id, ...
                        'agent', packet.agent, 'kind', packet.kind, 'source_time', packet.generated_at, ...
                        'age_seconds', at - packet.generated_at, 'version', packet.version, ...
                        'bytes', packet.size_bytes + header));
                    delivered{end + 1} = packet; %#ok<AGROW>
                    if nargin >= 3 && ~isempty(receiver)
                        receiver(packet);
                    end
                    continue;
                end
                name = packet.route{hop + 1};
                if startsWith(name, 'process:')
                    obj.event(at + str2double(name(9:end)), 'enqueue', {packet, hop + 1, header});
                elseif ~physical
                    obj.event(at, 'enqueue', {packet, hop + 1, header});
                elseif isfield(obj.traces, name)
                    d = obj.traces.(name).delay(at + c.backhaul_time_offset_seconds);
                    obj.add_log(struct('event', 'trace_delay', 'time', at, 'id', packet.id, ...
                        'link', name, 'delay_seconds', d));
                    obj.event(at + d, 'enqueue', {packet, hop + 1, header});
                else
                    k = obj.link_index(name);
                    obj.push_back(k, packet.agent, ...
                        {panama_uav.transport.Queued(packet, hop, at, at), header});
                    obj.start(name);
                end
            end
            obj.now = double(until_time);
        end
        function finish = finish_transmission(obj, start, duration, satellite)
            %FINISH_TRANSMISSION End of a transmission (Transport._finish_transmission).
            %   Satellite links pause for handover_interruption_seconds at every
            %   multiple k*handover_interval_seconds, k >= 1, when handovers are
            %   enabled: a transmission that would cross a window boundary is
            %   split around the pause, and one that starts inside a pause waits
            %   for its end. As in Python, a remaining time of at most 1e-14 s
            %   counts as done (so a residue that small still waits out the
            %   pause it reached), and a zero duration returns START even inside
            %   a pause.
            %
            %   Python loops forever when the state stops changing: with a zero
            %   interruption, floor(window / interval) can round down at a
            %   window boundary (12 * 0.7 = 8.399999999999999 and
            %   floor(8.399999999999999 / 0.7) = 11), leaving no time available
            %   and the cursor where it was. The port raises panama_uav:transport
            %   there instead of hanging.
            c = obj.config;
            if ~satellite || ~c.handover_enabled
                finish = start + duration;
                return;
            end
            interval = c.handover_interval_seconds;
            pause = c.handover_interruption_seconds;
            remaining = duration;
            time = start;
            while remaining > 1e-14
                index = floor(time / interval);
                window = index * interval;
                if index > 0 && time < window + pause
                    time = window + pause;
                end
                next_window = (floor(time / interval) + 1) * interval;
                available = next_window - time;
                if remaining <= available
                    finish = time + remaining;
                    return;
                end
                if available <= 0 && next_window + pause == time
                    error('panama_uav:transport', ['Handover pauses make no progress at %.17g s ', ...
                        '(interval %.17g s, interruption %.17g s); Python''s ', ...
                        '_finish_transmission never returns here'], time, interval, pause);
                end
                remaining = remaining - available;
                time = next_window + pause;
            end
            finish = time;
        end
        function w = handover_windows(obj, start, finish)
            %HANDOVER_WINDOWS Periodic pause windows overlapping [START, FINISH]
            %   (Transport.handover_windows), K-by-2 [start end]; empty outside
            %   the physical profile or with handovers disabled.
            c = obj.config;
            w = zeros(0, 2);
            if ~strcmp(c.profile, 'physical') || ~c.handover_enabled
                return;
            end
            interval = c.handover_interval_seconds;
            pause = c.handover_interruption_seconds;
            for i = max(1, floor(start / interval)):floor(finish / interval)
                if i * interval + pause >= start
                    w(end + 1, :) = [i * interval, i * interval + pause]; %#ok<AGROW>
                end
            end
        end
        function result = occupancy(obj)
            %OCCUPANCY Bytes held per link queue, in reservation buffers, in
            %   flight and still to transmit (Transport.occupancy).
            result = struct();
            for k = 1:numel(obj.links)
                total = 0;
                queues = obj.links(k).queues;
                for j = 1:numel(queues)
                    for e = 1:numel(queues{j})
                        q = queues{j}{e}{1};
                        if isempty(q.remaining_bytes)
                            total = total + q.message.size_bytes + queues{j}{e}{2};
                        else
                            total = total + q.remaining_bytes;
                        end
                    end
                end
                result.(obj.links(k).name) = total;
            end
            records = obj.calendar.pending();
            buffer = 0;
            flight = 0;
            transmitting = 0;
            for k = 1:numel(records)
                [at, ~, kind, value] = records{k}{:};
                if strcmp(kind, 'enqueue')
                    if value{2} == 0 && at > obj.now
                        buffer = buffer + value{1}.size_bytes + value{3};
                    elseif value{2} > 0
                        flight = flight + value{1}.size_bytes + value{3};
                    end
                elseif strcmp(kind, 'free') && iscell(value)
                    transmitting = transmitting + value{2}.remaining_bytes;
                end
            end
            result.reservation_buffer = buffer;
            result.in_flight = flight;
            result.transmitting_remaining = transmitting;
        end
    end
    methods (Access = private)
        function start(obj, name)
            % Transport._start: serve the next eligible agent on a free link.
            k = obj.link_index(name);
            L = obj.links(k);
            if L.busy
                return;
            end
            eligible = zeros(1, 0);
            for j = 1:numel(L.agents)
                if ~isempty(L.queues{j}) && L.queues{j}{1}{1}.ready_at <= obj.now + 1e-12
                    eligible(end + 1) = L.agents(j); %#ok<AGROW>
                end
            end
            if isempty(eligible)
                return;
            end
            eligible = sort(eligible);
            later = eligible(eligible > L.last_agent);
            if isempty(later)
                agent = eligible(1);
            else
                agent = later(1);
            end
            j = find(L.agents == agent, 1);
            entry = L.queues{j}{1};
            L.queues{j}(1) = [];
            L.last_agent = agent;
            L.busy = true;
            obj.links(k) = L;
            q = entry{1};
            header = entry{2};
            c = obj.config;
            satellite = startsWith(name, 'satellite');
            if isempty(q.remaining_bytes)
                q.remaining_bytes = q.message.size_bytes + header;
            end
            fragmented = c.packet_payload_bytes > 0;
            if fragmented
                served = min(q.remaining_bytes, c.packet_payload_bytes);
                % Chunk-level scheduling aggregates ordinary 1500-byte packets.
                wire = served + ceil(served / 1500) * c.packet_overhead_bytes;
            else
                served = q.remaining_bytes;
                wire = served;
            end
            duration = wire * 8 / L.capacity_bps;
            guard = 0.0;
            finish = obj.finish_transmission(obj.now, duration, satellite);
            interrupted = finish - obj.now - duration;
            if satellite
                propagation = c.one_way_propagation_seconds;
            else
                propagation = 0.0;
            end
            q.transmitted_bytes = q.transmitted_bytes + wire;
            q.transmission_seconds = q.transmission_seconds + duration;
            q.interruption_seconds = q.interruption_seconds + interrupted;
            q.guard_seconds = q.guard_seconds + guard;
            q.queue_seconds = q.queue_seconds + (obj.now - q.ready_at);
            q.chunks = q.chunks + 1;
            if isempty(q.first_start)
                q.first_start = obj.now;
            end
            q.remaining_bytes = q.remaining_bytes - served;
            done = q.remaining_bytes == 0;
            if c.log_service_chunks || done
                if done
                    entry_kind = 'transmit';
                    time = q.first_start;
                    bytes = q.transmitted_bytes;
                    payload_bytes = q.message.size_bytes + header;
                else
                    entry_kind = 'service_chunk';
                    time = obj.now;
                    bytes = wire;
                    payload_bytes = served;
                end
                obj.add_log(struct('event', entry_kind, 'time', time, 'id', q.message.id, ...
                    'agent', agent, 'link', name, 'bytes', bytes, 'payload_bytes', payload_bytes, ...
                    'chunks', q.chunks, 'kind', q.message.kind, 'queue_seconds', q.queue_seconds, ...
                    'transmission_seconds', q.transmission_seconds, ...
                    'handover_seconds', q.interruption_seconds, 'frame_guard_seconds', q.guard_seconds, ...
                    'propagation_seconds', propagation, 'finish', finish));
            end
            q.ready_at = finish;
            q.latest_arrival = max(q.latest_arrival, finish + propagation);
            if done
                obj.event(finish, 'free', name);
                obj.event(q.latest_arrival, 'enqueue', {q.message, q.hop + 1, header});
            else
                obj.event(finish, 'free', {name, q, header});
            end
            obj.counters.hop_bytes_transmitted = obj.counters.hop_bytes_transmitted + wire;
        end
        function k = link_index(obj, name)
            k = find(strcmp(obj.LINK_NAMES, name), 1);
            if isempty(k)
                error('panama_uav:transport', 'Unknown link ''%s''', name);   % Python: KeyError
            end
        end
        function j = queue_slot(obj, k, agent)
            j = find(obj.links(k).agents == agent, 1);
            if isempty(j)
                obj.links(k).agents(end + 1) = agent;
                obj.links(k).queues{end + 1} = {};
                j = numel(obj.links(k).agents);
            end
        end
        function push_back(obj, k, agent, entry)
            j = obj.queue_slot(k, agent);
            queue = obj.links(k).queues{j};
            queue{end + 1} = entry;
            obj.links(k).queues{j} = queue;
        end
        function push_front(obj, k, agent, entry)
            j = obj.queue_slot(k, agent);
            obj.links(k).queues{j} = [{entry}, obj.links(k).queues{j}];
        end
        function event(obj, at, kind, value)
            obj.sequence = obj.sequence + 1;
            obj.calendar.schedule(double(at), kind, value);
        end
        function add_log(obj, entry)
            obj.log{end + 1} = entry;
        end
    end
end
