function validate_transport(t)
%VALIDATE_TRANSPORT Checks of TransportConfig.__post_init__ (src/panama_uav/config.py).
    err = @(msg) error('panama_uav:config', '%s', msg);   % '%s': messages are literal
    if ~any(strcmp(t.profile, {'perfect', 'controlled', 'physical'}))
        err('Unknown communication profile');
    end
    if ~any(strcmp(t.mission_route, {'uav', 'cloud'}))
        err('Unknown mission route');
    end
    if ~isempty(setdiff(t.stale_information, {'task', 'intentions', 'priorities'}))
        err('Unknown stale information');
    end
    if t.seconds_per_step <= 0 || t.delay_steps < 0
        err('Invalid simulated time');
    end
    if t.backhaul_time_offset_seconds < 0
        err('Backhaul timeline offset must be nonnegative');
    end
    if t.packet_payload_bytes < 0 || t.packet_overhead_bytes < 0
        err('Invalid packet sizes');
    end
    if t.scheduler_frame_seconds <= 0 || ~(0 <= t.scheduler_guard_fraction && t.scheduler_guard_fraction < 1)
        err('Invalid scheduling frame');
    end
    if t.orbital_replay && isempty(t.leo_timeline)
        err('Orbital replay requires an archived timeline');
    end
    if ~any(strcmp(t.model_distribution, {'per_agent', 'uav_fanout'}))
        err('Unknown model distribution route');
    end
    if ~isempty(t.leo_timeline) && (~isempty(t.uplink_trace) || ~isempty(t.downlink_trace))
        err('Use orbital modeling or empirical delay traces separately; do not double-count');
    end
    if ~(1 <= t.windows_min && t.windows_min <= t.windows_max && t.windows_max <= 2)
        err('Use one or two reservation windows');
    end
    if t.reservation_steps < 1
        err('Invalid reservation duration');
    end
    if min([t.access_uplink_mbps, t.access_downlink_mbps, t.satellite_uplink_mbps, ...
            t.satellite_downlink_mbps]) <= 0
        err('Capacity must be positive');
    end
    if t.one_way_propagation_seconds < 0 || t.handover_interval_seconds <= 0 ...
            || t.handover_interruption_seconds < 0
        err('Invalid physical delays');
    end
end
