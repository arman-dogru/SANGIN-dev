function [r, v, err] = sgp4_propagate(satrec, minutes) %#ok<STOUT,INUSD>
%SGP4_PROPAGATE SGP4 propagation (Aerospace Toolbox propagateOrbit could replace).
%   Python source: sgp4 2.27 (Satrec.sgp4) used by scripts/build_leo_timeline.py
%   Status: stub, milestone M5. Raises panama_uav:notImplemented.
    error('panama_uav:notImplemented', 'sgp4_propagate is not ported yet (Python: sgp4 2.27 (Satrec.sgp4) used by scripts/build_leo_timeline.py; milestone M5). See matlab/PORT_PLAN.md.');
end
