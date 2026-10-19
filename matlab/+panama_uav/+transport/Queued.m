classdef Queued < handle
    %QUEUED A message waiting for, or partly through, one link (transport.py:Queued).
    %   A handle, because Python mutates the same Queued object from the
    %   link queue and from the pending 'free' event of a partly served
    %   message. REMAINING_BYTES is [] until service starts (Python None);
    %   FIRST_START is [] until the first chunk.
    properties
        message
        hop = 0
        entered_at = 0.0
        ready_at = 0.0
        remaining_bytes = []
        latest_arrival = 0.0
        transmitted_bytes = 0
        transmission_seconds = 0.0
        interruption_seconds = 0.0
        guard_seconds = 0.0
        queue_seconds = 0.0
        chunks = 0
        first_start = []
    end
    methods
        function obj = Queued(message, hop, entered_at, ready_at)
            obj.message = message;
            obj.hop = hop;
            obj.entered_at = entered_at;
            obj.ready_at = ready_at;
        end
    end
end
