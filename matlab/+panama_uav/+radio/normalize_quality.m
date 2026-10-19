function q = normalize_quality(values_db, threshold_db, maximum_db)
%NORMALIZE_QUALITY Clip (v - threshold)/(max - threshold) to [0,1] as single (radio.py).
    span = maximum_db - threshold_db;
    if span <= 0
        error('panama_uav:radio', 'normalization_max_db must exceed blackout_threshold_db');
    end
    q = single(min(max((values_db - threshold_db) / span, 0.0), 1.0));
end
