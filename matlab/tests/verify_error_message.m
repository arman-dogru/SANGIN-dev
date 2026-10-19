function verify_error_message(tc, fn, id, message, label)
%VERIFY_ERROR_MESSAGE FN must raise error ID with exactly MESSAGE (Python's text).
    raised = [];
    try
        fn();
    catch err
        raised = err;
    end
    tc.verifyFalse(isempty(raised), [label, ': no error raised']);
    if ~isempty(raised)
        tc.verifyEqual(raised.identifier, id, [label, ' identifier']);
        tc.verifyEqual(raised.message, message, [label, ' message']);
    end
end
