classdef TransportTest < matlab.unittest.TestCase
    % Parity: the physical profile (link service, round robin, fragmentation,
    % handover pauses, propagation, delay traces, byte counters, occupancy)
    % vs Python's Transport, replayed op by op from make_fixtures.py:group_physical.
    %
    % Tolerance: none. Every logged time and duration is compared bit for
    % bit, because the port performs the same IEEE-754 double operations in
    % the same order as Python (capacity * 1e6, bytes * 8 / bps, floor and
    % ceil, sums of the same terms) and calls no libm function whose last
    % ulp could differ. Byte counts are integers and compared exactly.
    methods (Test)
        function testScenariosMatchPython(tc)
            fx = load_fixture('physical');
            names = fieldnames(fx.scenarios);
            tc.verifyEqual(numel(names), 30);
            for k = 1:numel(names)
                replay(tc, names{k}, fx.scenarios.(names{k}));
            end
        end
        function testFinishTransmissionMatchesPython(tc)
            % 300 seeded cases around window boundaries and pauses, plus six
            % zero-interruption cases: four return, and two make Python loop
            % forever, where the port raises panama_uav:transport instead.
            fx = load_fixture('physical');
            cases = as_cell(fx.finish);
            tc.verifyEqual(numel(cases), 306);
            hangs = 0;
            for k = 1:numel(cases)
                c = cases{k};
                t = transport_for(struct('profile', 'physical', 'handover_enabled', c.enabled, ...
                    'handover_interval_seconds', c.interval, 'handover_interruption_seconds', c.pause));
                start = panama_uav.util.hex_to_double(c.start);
                duration = panama_uav.util.hex_to_double(c.duration);
                label = sprintf('finish case %d', k);
                if isfield(c, 'hangs')
                    hangs = hangs + 1;
                    tc.verifyError(@() t.finish_transmission(start, duration, c.satellite), ...
                        'panama_uav:transport', label);
                else
                    tc.verifyEqual(typecast(t.finish_transmission(start, duration, c.satellite), 'uint64'), ...
                        typecast(panama_uav.util.hex_to_double(c.finish), 'uint64'), label);
                end
            end
            tc.verifyEqual(hangs, 2);
        end
        function testUnknownLinkAndOrbitRaise(tc)
            t = transport_for(struct('profile', 'physical', 'contention_enabled', false));
            t.send(0, 'x', struct(), 'route', {'laser'});
            tc.verifyError(@() t.advance(1), 'panama_uav:transport');
            c = panama_uav.config.transport_defaults();
            c.profile = 'physical';
            c.leo_timeline = 'timeline.npz';
            tc.verifyError(@() panama_uav.transport.Transport(c), 'panama_uav:notImplemented');
            % A payload with no Python type (a numeric array: tuple, list or
            % NumPy array?) is refused by the physical profile; the other
            % profiles record unknown (NaN) sizes. Mission payloads are
            % sized by MissionCommunication through mission_wire instead.
            t = transport_for(struct('profile', 'physical'));
            tc.verifyError(@() t.send(0, 'report', struct('position', [1 2])), 'panama_uav:notImplemented');
            t = transport_for(struct('profile', 'controlled'));
            t.send(0, 'report', struct('position', [1 2]));
            tc.verifyTrue(isnan(t.counters.bytes_generated));
        end
    end
end

function t = transport_for(changes)
    c = panama_uav.config.transport_defaults();
    for f = reshape(fieldnames(changes), 1, [])
        c.(f{1}) = changes.(f{1});
    end
    t = panama_uav.transport.Transport(c);
end

function replay(tc, name, record)
    changes = record.config;
    if isempty(changes)
        changes = struct();
    end
    for key = {'uplink_trace', 'downlink_trace'}
        if isfield(changes, key{1})
            changes.(key{1}) = fullfile(repo_root(), 'matlab', 'tests', 'fixtures', changes.(key{1}));
        end
    end
    if isfield(record, 'constructor_error')
        verify_error_message(tc, @() transport_for(changes), 'panama_uav:trace', ...
            record.constructor_error, [name, ' constructor']);
        return;
    end
    t = transport_for(changes);
    ops = as_cell(record.ops);
    results = as_cell(record.results);
    tc.verifyEqual(numel(ops), numel(results), [name, ' ops']);
    for k = 1:numel(ops)
        op = ops{k};
        want = results{k};
        label = sprintf('%s op %d (%s)', name, k, op.op);
        if isfield(want, 'error')
            id = 'panama_uav:transport';
            if ~isempty(strfind(want.error, 'trace segment'))
                id = 'panama_uav:trace';
            end
            verify_error_message(tc, @() run_op(t, op), id, want.error, label);
            break;
        end
        got = run_op(t, op);
        switch op.op
            case 'send'
                tc.verifyEqual(got, want.value, label);
            case 'advance'
                tc.verifyEqual(reshape(got, 1, []), reshape(double(want.value), 1, []), label);
            case 'occupancy'
                check_tagged(tc, got, want.value, label);
            case 'handover_windows'
                w = as_cell(want.value);
                tc.verifyEqual(size(got, 1), numel(w), [label, ' count']);
                for j = 1:min(size(got, 1), numel(w))
                    check_tagged(tc, num2cell(got(j, :)), w{j}, sprintf('%s window %d', label, j));
                end
        end
    end
    logs = as_cell(record.log);
    tc.verifyEqual(numel(t.log), numel(logs), [name, ' log length']);
    for j = 1:min(numel(t.log), numel(logs))
        check_tagged(tc, t.log{j}, logs{j}, sprintf('%s log %d', name, j));
    end
    counters = fieldnames(t.counters);
    want = record.counters;
    tc.verifyTrue(all(ismember(fieldnames(want), counters)), [name, ' counter names']);
    for j = 1:numel(counters)
        expected = 0;
        if isfield(want, counters{j})
            expected = want.(counters{j});
        end
        tc.verifyEqual(t.counters.(counters{j}), expected, [name, ' counter ', counters{j}]);
    end
    tc.verifyEqual(typecast(t.now, 'uint64'), typecast(panama_uav.util.hex_to_double(record.now), 'uint64'), ...
        [name, ' now']);
end

function got = run_op(t, op)
    got = [];
    switch op.op
        case 'send'
            args = {'route', as_cellstr(op.route)};
            if isfield(op, 'version'), args = [args, {'version', op.version}]; end
            if isfield(op, 'delayed'), args = [args, {'delayed', logical(op.delayed)}]; end
            if isfield(op, 'generated_at')
                args = [args, {'generated_at', panama_uav.util.hex_to_double(op.generated_at)}];
            end
            if isfield(op, 'wire_n'), args = [args, {'wire_bytes', op.wire_n}]; end
            got = t.send(op.agent, op.kind, py_value(op.payload), args{:});
        case 'advance'
            delivered = t.advance(panama_uav.util.hex_to_double(op.to));
            got = cellfun(@(p) p.id, delivered);
            if isempty(got)
                got = zeros(1, 0);
            end
        case 'windows'
            entries = as_cell(op.windows);
            t.windows = {};
            for j = 1:numel(entries)
                spans = as_cell(entries{j}.spans);
                w = zeros(numel(spans), 2);
                for s = 1:numel(spans)
                    w(s, :) = panama_uav.util.hex_to_double(as_cell(spans{s}));
                end
                t.windows{entries{j}.agent + 1} = w;
            end
        case 'occupancy'
            got = t.occupancy();
        case 'handover_windows'
            got = t.handover_windows(panama_uav.util.hex_to_double(op.start), ...
                panama_uav.util.hex_to_double(op.stop));
    end
end

function c = as_cellstr(x)
    if isempty(x)
        c = {};
    elseif ischar(x)
        c = {x};
    else
        c = reshape(cellstr(x), 1, []);
    end
end
