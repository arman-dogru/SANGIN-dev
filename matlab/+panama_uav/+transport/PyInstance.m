classdef PyInstance
    %PYINSTANCE An instance of a plain Python class (a dataclass), for encode_size.
    %   O = panama_uav.transport.PyInstance(MODULE, QUALNAME, STATE) stands
    %   for an object that pickles by the default object.__reduce_ex__(5):
    %   the class by reference (MODULE and QUALNAME as two strs and
    %   STACK_GLOBAL), an empty argument tuple and NEWOBJ, then STATE (the
    %   instance __dict__, a scalar struct or PyDict) and BUILD. This is how
    %   information.Guidance is sent: PyInstance('panama_uav.information',
    %   'Guidance', struct('route', ..., 'reported_distance', ...)).
    %   Classes with __slots__, __getstate__, __reduce__ or a copyreg
    %   extension code pickle differently and are not covered.
    properties
        module = ''
        qualname = ''
        state = struct()
    end
    methods
        function obj = PyInstance(module, qualname, state)
            if nargin == 0
                return;
            end
            if ~ischar(module) || ~ischar(qualname) || isempty(module) || isempty(qualname)
                error('panama_uav:encode', 'PyInstance needs a module and a qualified name');
            end
            obj.module = module;
            obj.qualname = qualname;
            obj.state = state;
        end
    end
end
