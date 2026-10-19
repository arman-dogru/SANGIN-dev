function tf = is_octave()
%IS_OCTAVE True when running under GNU Octave.
    tf = exist('OCTAVE_VERSION', 'builtin') ~= 0;
end
