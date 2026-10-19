function [loss, dpred] = huber_loss(pred, target, weights) %#ok<STOUT,INUSD>
%HUBER_LOSS Weighted Huber loss and gradient.
%   Python source: torch.nn.functional.smooth_l1_loss / huber (learning.py)
%   Status: stub, milestone M2. Raises panama_uav:notImplemented.
    error('panama_uav:notImplemented', 'huber_loss is not ported yet (Python: torch.nn.functional.smooth_l1_loss / huber (learning.py); milestone M2). See matlab/PORT_PLAN.md.');
end
