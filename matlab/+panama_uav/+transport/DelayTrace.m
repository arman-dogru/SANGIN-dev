classdef DelayTrace < handle
    %DELAYTRACE Imported one-way delay trace (src/panama_uav/transport.py:DelayTrace).
    %
    %   T = panama_uav.transport.DelayTrace.load(PATH) reads the .npz written
    %   by Python's import_trace: 'timestamps' and 'delays' (float64 seconds,
    %   N-by-1 here) and 'metadata' (a JSON string, decoded to a struct).
    %   T = panama_uav.transport.DelayTrace(TIMESTAMPS, DELAYS, METADATA)
    %   builds one directly.
    %
    %   D = T.delay(TIME) is the delay of the last sample at or before TIME
    %   (np.searchsorted(..., side='right') - 1), so the trace is a step
    %   function. TIME outside [timestamps(1), timestamps(end)] raises
    %   panama_uav:trace with Python's message. Like Python, nothing checks
    %   that the stored timestamps are sorted (import_trace guarantees it);
    %   for sorted timestamps the count of samples <= TIME is what
    %   searchsorted returns. A NaN TIME passes Python's range check (both
    %   comparisons are false) and searchsorted puts NaN last, so it gets
    %   the last delay; the port does the same.
    properties
        timestamps = zeros(0, 1)
        delays = zeros(0, 1)
        metadata = struct()
    end
    methods
        function obj = DelayTrace(timestamps, delays, metadata)
            if nargin >= 1
                obj.timestamps = double(timestamps(:));
                obj.delays = double(delays(:));
                obj.metadata = metadata;
            end
        end
        function d = delay(obj, time)
            ts = obj.timestamps;
            if isempty(ts)
                % Python: IndexError on timestamps[0].
                error('panama_uav:trace', 'index 0 is out of bounds for axis 0 with size 0');
            end
            if time < ts(1) || time > ts(end)
                error('panama_uav:trace', ...
                    'Simulation exceeds imported trace segment; select a longer segment');
            end
            if isnan(time)
                index = numel(ts);
            else
                index = max(1, sum(ts <= time));
            end
            d = obj.delays(index);
        end
    end
    methods (Static)
        function obj = load(path)
            data = panama_uav.util.read_npz(path, {'timestamps', 'delays', 'metadata'});
            obj = panama_uav.transport.DelayTrace(data.timestamps, data.delays, ...
                jsondecode(data.metadata));
        end
    end
end
