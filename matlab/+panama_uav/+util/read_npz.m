function data = read_npz(path, names)
%READ_NPZ Read named arrays from a NumPy .npz archive (np.savez or np.savez_compressed).
%   DATA = panama_uav.util.read_npz(PATH, NAMES) returns a struct with one
%   field per name in the cellstr NAMES, each read from the member
%   '<name>.npy' by panama_uav.util.read_npy. Like np.load(PATH,
%   allow_pickle=false), only the requested members are read, and a missing
%   member is an error (panama_uav:npy).
%
%   An .npz is a ZIP archive (deflated for savez_compressed, ZIP64 local
%   headers). It is extracted with the built-in unzip into a temporary
%   folder that is removed afterwards; on Octave, unzip calls the system
%   'unzip' program, which must be installed.
    if ~exist(path, 'file')
        error('panama_uav:npy', 'No such file: %s', path);
    end
    folder = tempname();
    mkdir(folder);
    cleaner = onCleanup(@() rmdir(folder, 's'));
    try
        files = unzip(path, folder);
    catch err
        error('panama_uav:npy', 'Cannot read %s as an .npz archive: %s', path, err.message);
    end
    members = cell(size(files));
    for k = 1:numel(files)
        if ~panama_uav.util.is_absolute(files{k})
            files{k} = fullfile(folder, files{k});   % Octave returns names relative to FOLDER
        end
        [~, base, ext] = fileparts(files{k});
        members{k} = [base, ext];
    end
    data = struct();
    for k = 1:numel(names)
        j = find(strcmp(members, [names{k}, '.npy']), 1);
        if isempty(j)
            error('panama_uav:npy', '%s is not a file in the archive %s', names{k}, path);
        end
        data.(names{k}) = panama_uav.util.read_npy(files{j});
    end
    clear cleaner;
end
