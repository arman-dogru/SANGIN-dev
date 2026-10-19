classdef DQN < handle
    %DQN Dual-stream DQN (Conv 3x3x32, Conv 3x3x64, MaxPool 2, vector MLP 64/32, head 512/5).
    %   Python source: src/panama_uav/models.py:DQN
    %   Status: stub, milestone M2. Every method raises panama_uav:notImplemented.
    methods
        function obj = DQN(varargin) %#ok<STOUT,INUSD>
            error('panama_uav:notImplemented', 'DQN is not ported yet (Python: models.py:DQN; milestone M2). See docs/matlab/PORT_PLAN.md.');
        end
    end
end
