classdef CalendarTest < matlab.unittest.TestCase
    % Parity: EventCalendar vs the SimPy-backed Python calendar.
    methods (Test)
        function testReplayMatchesSimPy(tc)
            fx = load_fixture('calendar');
            ops = as_cell(fx.ops);
            cal = panama_uav.transport.EventCalendar();
            for k = 1:numel(ops)
                op = ops{k};
                if strcmp(op.op, 'schedule')
                    cal.schedule(panama_uav.util.hex_to_double(op.at_hex), 'e', op.value);
                else
                    [at, token, ~, value] = cal.pop();
                    tc.verifyEqual(at, panama_uav.util.hex_to_double(op.at_hex), sprintf('op %d time', k));
                    tc.verifyEqual(token, op.token, sprintf('op %d token', k));
                    tc.verifyEqual(value, op.value, sprintf('op %d value', k));
                    tc.verifyEqual(cal.peek(), panama_uav.util.hex_to_double(op.peek_hex), sprintf('op %d peek', k));
                end
            end
            tc.verifyEqual(cal.count(), 0);
        end
        function testRejectsPast(tc)
            cal = panama_uav.transport.EventCalendar();
            cal.schedule(2.0, 'e', 1);
            cal.pop();
            tc.verifyError(@() cal.schedule(1.0, 'e', 2), 'panama_uav:calendar');
        end
    end
end
