-- MacroDaddy
-- Native FFXI macro backup addon for Windower 4
-- v0.1.1
--
-- Scope:
--   * Backs up native FFXI macro data only.
--   * Does NOT back up equipment sets, map markers, FFXI config, GearSwap,
--     Windower settings, or other unrelated USER data.
--
-- Macro files included:
--   mcr.dat
--   mcr1.dat, mcr2.dat, ... (all numbered mcr*.dat files)
--   mcr.sys
--   mcr.ttl
--   mcr_2.ttl
--
-- Automatic backup triggers are independently configurable:
--   login, logout, job change, zone change
--
-- Duplicate snapshots are skipped when the macro data has not changed.
--
-- Backup location:
--   Windower\addons\MacroDaddy\backups\

_addon.name = 'MacroDaddy'
_addon.author = 'MacroDaddy project'
_addon.version = '0.1.1'
_addon.commands = {'macrodaddy', 'md'}

local config = require('config')

local function default_backup_root()
    -- Keep MacroDaddy self-contained.
    return windower.addon_path .. 'backups'
end

local defaults = {
    backup_root = default_backup_root(),

    triggers = {
        login = true,
        logout = true,
        jobchange = false,
        zonechange = false,
    },

    -- Last complete source signature/snapshot. Used only to avoid
    -- identical snapshots when the prior backup still exists.
    last_signature = '',
    last_snapshot = '',
}

local settings = config.load(defaults)

local CHAT_COLOR = 207
local PREFIX = '[MacroDaddy] '

local function msg(text)
    windower.add_to_chat(CHAT_COLOR, PREFIX .. tostring(text))
end

local function join_path(a, b)
    if not a or a == '' then
        return b
    end

    local last = a:sub(-1)
    if last == '\\' or last == '/' then
        return a .. b
    end

    return a .. '\\' .. b
end

local function trim_trailing_slashes(path)
    while #path > 3 do
        local last = path:sub(-1)
        if last == '\\' or last == '/' then
            path = path:sub(1, -2)
        else
            break
        end
    end
    return path
end

-- windower.create_dir() creates only the final directory and requires its
-- parent to exist. This helper creates a full Windows directory tree.
local function ensure_dir_tree(path)
    path = trim_trailing_slashes(path)

    if windower.dir_exists(path) then
        return true
    end

    local drive, rest = path:match('^(%a:[\\/])(.*)$')
    local current

    if drive then
        current = drive
    else
        current = ''
        rest = path
    end

    for part in rest:gmatch('[^\\/]+') do
        if current == '' then
            current = part
        elseif current:sub(-1) == '\\' or current:sub(-1) == '/' then
            current = current .. part
        else
            current = current .. '\\' .. part
        end

        if not windower.dir_exists(current) then
            local ok, err = windower.create_dir(current)
            if not ok and not windower.dir_exists(current) then
                return false, err or ('Unable to create directory: ' .. current)
            end
        end
    end

    return windower.dir_exists(path), windower.dir_exists(path) and nil or ('Unable to create directory: ' .. path)
end

local function is_macro_file(name)
    local lower = name:lower()

    if lower == 'mcr.dat'
        or lower == 'mcr.sys'
        or lower == 'mcr.ttl'
        or lower == 'mcr_2.ttl' then
        return true
    end

    -- Numbered macro palette files only: mcr1.dat, mcr2.dat, ...
    -- Deliberately does not match nmcr*.dat.
    return lower:match('^mcr%d+%.dat$') ~= nil
end

local function read_file(path)
    local f, err = io.open(path, 'rb')
    if not f then
        return nil, err
    end

    local data = f:read('*a')
    f:close()
    return data
end

-- Pure-Lua Adler-32. This is not intended as a security hash; it is used
-- for change detection and copy verification.
local function adler32(data)
    local MOD_ADLER = 65521
    local a = 1
    local b = 0

    for i = 1, #data do
        a = (a + data:byte(i)) % MOD_ADLER
        b = (b + a) % MOD_ADLER
    end

    return b * 65536 + a
end

local function file_signature(path)
    local data, err = read_file(path)
    if data == nil then
        return nil, err
    end

    return {
        size = #data,
        checksum = adler32(data),
        data = data,
    }
end

local function get_user_path()
    return join_path(windower.ffxi_path, 'USER')
end

-- Returns all native macro files from every character directory that
-- currently exists in FINAL FANTASY XI\USER.
--
-- We intentionally scan all character folders rather than guessing which
-- hexadecimal USER folder belongs to the currently logged-in character.
local function discover_macro_files()
    local user_path = get_user_path()

    if not windower.dir_exists(user_path) then
        return nil, 'FFXI USER directory was not found: ' .. user_path
    end

    local entries = windower.get_dir(user_path) or {}
    table.sort(entries)

    local files = {}

    for _, entry in ipairs(entries) do
        local char_path = join_path(user_path, entry)

        if windower.dir_exists(char_path) then
            local char_entries = windower.get_dir(char_path) or {}
            table.sort(char_entries)

            for _, filename in ipairs(char_entries) do
                if is_macro_file(filename) then
                    local source = join_path(char_path, filename)

                    if windower.file_exists(source) then
                        files[#files + 1] = {
                            character_folder = entry,
                            filename = filename,
                            source = source,
                            relative = entry .. '\\' .. filename,
                        }
                    end
                end
            end
        end
    end

    table.sort(files, function(a, b)
        return a.relative:lower() < b.relative:lower()
    end)

    return files
end

local function build_source_state(files)
    local state = {}
    local signature_parts = {}

    for _, item in ipairs(files) do
        local sig, err = file_signature(item.source)
        if not sig then
            return nil, nil, ('Unable to read %s: %s'):format(item.source, tostring(err))
        end

        state[#state + 1] = {
            character_folder = item.character_folder,
            filename = item.filename,
            source = item.source,
            relative = item.relative,
            size = sig.size,
            checksum = sig.checksum,
            data = sig.data,
        }

        signature_parts[#signature_parts + 1] =
            item.relative:lower() .. ':' .. tostring(sig.size) .. ':' .. tostring(sig.checksum)
    end

    -- The source signature is deterministic because the input list is sorted.
    local combined = table.concat(signature_parts, '|')
    local signature = tostring(#files) .. ':' .. tostring(adler32(combined))

    return state, signature
end

local function current_character_name()
    local player = windower.ffxi.get_player()
    local name = player and player.name or 'UnknownCharacter'

    -- Keep the folder name Windows-safe.
    name = tostring(name):gsub('[<>:"/\\|%?%*]', '_')
    if name == '' then
        name = 'UnknownCharacter'
    end

    return name
end

local function sanitize_reason(reason)
    reason = tostring(reason or 'Manual')
    reason = reason:gsub('[^%w%-_]', '')
    if reason == '' then
        return 'Manual'
    end
    return reason
end

local function unique_snapshot_path(root, reason)
    local stamp = os.date('%Y-%m-%d_%H%M%S')
    local base = stamp .. '_' .. sanitize_reason(reason)
    local path = join_path(root, base)

    if not windower.dir_exists(path) then
        return path
    end

    local n = 2
    while windower.dir_exists(path .. '_' .. tostring(n)) do
        n = n + 1
    end

    return path .. '_' .. tostring(n)
end

local function write_verified_file(path, data, expected_checksum)
    local f, err = io.open(path, 'wb')
    if not f then
        return false, err
    end

    local ok, write_err = f:write(data)
    f:flush()
    f:close()

    if not ok then
        return false, write_err or 'Write failed.'
    end

    local verify, verify_err = file_signature(path)
    if not verify then
        return false, verify_err
    end

    if verify.size ~= #data then
        return false, ('Size verification failed: expected %d, got %d.'):format(#data, verify.size)
    end

    if verify.checksum ~= expected_checksum then
        return false, ('Checksum verification failed: expected %u, got %u.'):format(expected_checksum, verify.checksum)
    end

    return true
end

local backup_in_progress = false

local function backup_macros(reason, force)
    if backup_in_progress then
        msg('Backup already in progress; skipping ' .. tostring(reason) .. ' trigger.')
        return false
    end

    backup_in_progress = true

    local function finish(result)
        backup_in_progress = false
        return result
    end

    local files, discover_err = discover_macro_files()
    if not files then
        msg('ERROR: ' .. tostring(discover_err))
        return finish(false)
    end

    if #files == 0 then
        msg('No native FFXI macro files were found under ' .. get_user_path())
        return finish(false)
    end

    local state, signature, state_err = build_source_state(files)
    if not state then
        msg('ERROR: ' .. tostring(state_err))
        return finish(false)
    end

    local previous_snapshot_exists =
        settings.last_snapshot
        and settings.last_snapshot ~= ''
        and windower.dir_exists(settings.last_snapshot)

    if not force
        and previous_snapshot_exists
        and settings.last_signature ~= ''
        and settings.last_signature == signature then

        msg(('%s: macros have not changed; no backup created.'):format(reason))
        return finish(true)
    end

    local root = trim_trailing_slashes(settings.backup_root)
    local ok, dir_err = ensure_dir_tree(root)
    if not ok then
        msg('ERROR creating backup root: ' .. tostring(dir_err))
        return finish(false)
    end

    local character_root = join_path(root, current_character_name())
    ok, dir_err = ensure_dir_tree(character_root)
    if not ok then
        msg('ERROR creating character backup root: ' .. tostring(dir_err))
        return finish(false)
    end

    local snapshot = unique_snapshot_path(character_root, reason)
    ok, dir_err = ensure_dir_tree(snapshot)
    if not ok then
        msg('ERROR creating snapshot: ' .. tostring(dir_err))
        return finish(false)
    end

    local copied = 0

    for _, item in ipairs(state) do
        local char_dest = join_path(snapshot, item.character_folder)

        ok, dir_err = ensure_dir_tree(char_dest)
        if not ok then
            msg('ERROR creating character backup folder: ' .. tostring(dir_err))
            return finish(false)
        end

        local destination = join_path(char_dest, item.filename)
        local copied_ok, copy_err = write_verified_file(destination, item.data, item.checksum)

        if not copied_ok then
            msg(('ERROR copying %s: %s'):format(item.relative, tostring(copy_err)))
            return finish(false)
        end

        copied = copied + 1
    end

    settings.last_signature = signature
    settings.last_snapshot = snapshot
    config.save(settings)

    msg(('%s backup complete: %d macro files -> %s'):format(reason, copied, snapshot))
    return finish(true)
end

local function set_trigger(name, enabled)
    if settings.triggers[name] == nil then
        return false
    end

    settings.triggers[name] = enabled
    config.save(settings)

    msg(('%s backups: %s'):format(name, enabled and 'ON' or 'OFF'))
    return true
end

local function set_all_triggers(enabled)
    settings.triggers.login = enabled
    settings.triggers.logout = enabled
    settings.triggers.jobchange = enabled
    settings.triggers.zonechange = enabled
    config.save(settings)

    msg('All automatic backup triggers: ' .. (enabled and 'ON' or 'OFF'))
end

local function bool_text(value)
    return value and 'ON' or 'OFF'
end

local function print_status()
    msg('MacroDaddy v' .. _addon.version)
    msg('Backup root: ' .. settings.backup_root)
    msg('Login: ' .. bool_text(settings.triggers.login)
        .. ' | Logout: ' .. bool_text(settings.triggers.logout)
        .. ' | Job Change: ' .. bool_text(settings.triggers.jobchange)
        .. ' | Zone Change: ' .. bool_text(settings.triggers.zonechange))
end

local function print_help()
    msg('MacroDaddy commands:')
    msg('//md backup              - Create a macro backup now')
    msg('//md status              - Show MacroDaddy version, backup path, and trigger settings')
    msg('//md help                - Show this complete command list')
    msg('//md login on|off        - Enable or disable automatic backups on login')
    msg('//md logout on|off       - Enable or disable automatic backups on logout')
    msg('//md jobchange on|off    - Enable or disable automatic backups on job change')
    msg('//md zonechange on|off   - Enable or disable automatic backups on zone change')
    msg('//md all on|off          - Enable or disable all four automatic backup triggers')
    msg('//md path                - Show the current backup destination')
    msg('//md path <folder>       - Change the backup destination to the specified folder')
end

local function parse_on_off(value)
    if not value then
        return nil
    end

    value = tostring(value):lower()

    if value == 'on' or value == 'true' or value == '1' or value == 'yes' then
        return true
    elseif value == 'off' or value == 'false' or value == '0' or value == 'no' then
        return false
    end

    return nil
end


local function strip_quotes(value)
    if not value then
        return value
    end

    if #value >= 2 then
        local first = value:sub(1, 1)
        local last = value:sub(-1)
        if (first == '"' and last == '"') or (first == "'" and last == "'") then
            return value:sub(2, -2)
        end
    end

    return value
end

windower.register_event('addon command', function(command, ...)
    command = command and command:lower() or 'help'
    local args = {...}

    if command == 'backup' then
        backup_macros('Manual', true)
        return
    end

    if command == 'status' then
        print_status()
        return
    end

    if command == 'help' then
        print_help()
        return
    end

    if command == 'all' then
        local enabled = parse_on_off(args[1])
        if enabled == nil then
            msg('Usage: //md all on|off')
            return
        end

        set_all_triggers(enabled)
        return
    end

    if command == 'login'
        or command == 'logout'
        or command == 'jobchange'
        or command == 'zonechange' then

        local enabled = parse_on_off(args[1])
        if enabled == nil then
            msg(('Usage: //md %s on|off'):format(command))
            return
        end

        set_trigger(command, enabled)
        return
    end

    if command == 'path' then
        if #args == 0 then
            msg('Backup root: ' .. settings.backup_root)
            return
        end

        local new_path = strip_quotes(table.concat(args, ' '))
        if not new_path or new_path == '' then
            msg('Usage: //md path <folder>')
            return
        end

        new_path = trim_trailing_slashes(new_path)

        local ok, err = ensure_dir_tree(new_path)
        if not ok then
            msg('ERROR: unable to use that path: ' .. tostring(err))
            return
        end

        settings.backup_root = new_path
        config.save(settings)
        msg('Backup root set to: ' .. new_path)
        return
    end

    msg('Unknown command: ' .. tostring(command))
    print_help()
end)

-- Login can occur while client state is still settling, so give the filesystem
-- a moment before taking the snapshot.
windower.register_event('login', function()
    if settings.triggers.login then
        coroutine.schedule(function()
            backup_macros('Login', false)
        end, 2)
    end
end)

-- Logout is synchronous so the backup happens before leaving the session.
windower.register_event('logout', function()
    if settings.triggers.logout then
        backup_macros('Logout', false)
    end
end)

windower.register_event('job change', function()
    if settings.triggers.jobchange then
        coroutine.schedule(function()
            backup_macros('JobChange', false)
        end, 1)
    end
end)

windower.register_event('zone change', function()
    if settings.triggers.zonechange then
        coroutine.schedule(function()
            backup_macros('ZoneChange', false)
        end, 1)
    end
end)

windower.register_event('load', function()
    msg('Loaded. Use //md status or //md help.')
end)
