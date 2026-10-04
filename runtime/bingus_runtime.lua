-- bingus_runtime.lua, version 1: the pieces every CowboyBingus mod used to
-- hand-roll, written and tested once. Canonical copy:
-- Resilience/runtime/bingus_runtime.lua. A mod vendors a byte-identical copy and
-- runs it once when it loads, e.g. local runtime = dofile_or_embedded()
-- (the result is a table; nothing is installed until the mod asks).
--
-- Copies of different versions can run in the same game: every FFI name carries
-- the version, and the session caches live in one shared global table,
-- BingusRuntime = {hashes, statuses, versions, hash_reads}.
--
-- What it gives a mod (KB resilience-v1-plan):
-- - Windows functions under private, versioned FFI names, declared once per
--   version. ffi.cdef keeps the first prototype of a name for the whole game, so
--   plain names would bind to whatever another mod declared first.
-- - memory(): reads through ReadProcessMemory into reused buffers (read_into
--   allocates nothing), so a bad address returns nil instead of crashing; writes
--   through WriteProcessMemory only into memory that is already committed,
--   private and read-write, checked with one VirtualQuery per region right
--   before the write; the SHA-256 of a game module is computed once per session
--   for every mod that asks.
-- - guard(): the update and shutdown wrappers. The previous update runs outside
--   pcall, so its errors reach the game unchanged (P1); the first failure
--   survives shutdown as "stopped after: <reason>" (P2); 8 errors stop the mod,
--   counted per burst so rare transient errors never add up (P3); a mod that can
--   restore its state pauses after an error below it and resumes when the
--   updates below run cleanly again; every argument and return value passes
--   through; a status table per mod lands in BingusRuntime.statuses.
--
-- Per-frame cost of a guard: the mod's step under pcall (as before), a few
-- boolean tests and stores and two integer counters around the previous update;
-- no allocation, closure or system call. A write costs one VirtualQuery per
-- memory region it touches (about 0.29 ms each in game), so write only on frames
-- that act. Unmeasured in game.
local runtime = {VERSION = 1}

local type, pcall, error, tostring, rawget, rawset, ipairs, select =
    type, pcall, error, tostring, rawget, rawset, ipairs, select
local max, format, concat = math.max, string.format, table.concat

-- Session state shared by every copy of every version ----------------------------

local SHARED = 'BingusRuntime'
local SHARED_TABLES = {'hashes', 'statuses', 'versions'}

-- Another copy, another version or another mod may have left the table
-- incomplete (even `BingusRuntime = {}`): missing or broken fields are filled in,
-- so one stray assignment cannot stop every mod on the runtime.
function runtime.shared(globals)
    globals = globals or _G
    local shared = rawget(globals, SHARED)
    if type(shared) ~= 'table' then
        shared = {}
        rawset(globals, SHARED, shared)
    end
    for _, field in ipairs(SHARED_TABLES) do
        if type(rawget(shared, field)) ~= 'table' then rawset(shared, field, {}) end
    end
    if type(rawget(shared, 'hash_reads')) ~= 'number' then rawset(shared, 'hash_reads', 0) end
    rawset(rawget(shared, 'versions'), runtime.VERSION, true)
    return shared
end

-- Windows functions --------------------------------------------------------------

local PREFIX = 'bingus_rt1_'
local DECLARATIONS = [[
    typedef struct bingus_rt1_region {
        void *base; void *allocation_base; uint32_t allocation_protection;
        uint16_t partition; uint16_t reserved; size_t size;
        uint32_t state; uint32_t protection; uint32_t type;
    } bingus_rt1_region;
    void *bingus_rt1_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
    uint32_t bingus_rt1_GetModuleFileNameW(void *module, uint16_t *path, uint32_t capacity) __asm__("GetModuleFileNameW");
    void *bingus_rt1_GetCurrentProcess(void) __asm__("GetCurrentProcess");
    int bingus_rt1_ReadProcessMemory(void *process, const void *address, void *buffer, size_t size,
                                     size_t *done) __asm__("ReadProcessMemory");
    int bingus_rt1_WriteProcessMemory(void *process, void *address, const void *buffer, size_t size,
                                      size_t *done) __asm__("WriteProcessMemory");
    size_t bingus_rt1_VirtualQuery(const void *address, bingus_rt1_region *region, size_t size) __asm__("VirtualQuery");
    void *bingus_rt1_CreateFileW(const uint16_t *path, uint32_t access, uint32_t share, void *security,
                                 uint32_t disposition, uint32_t flags, void *template_file) __asm__("CreateFileW");
    int bingus_rt1_ReadFile(void *file, void *buffer, uint32_t size, uint32_t *done, void *overlapped) __asm__("ReadFile");
    int bingus_rt1_CloseHandle(void *handle) __asm__("CloseHandle");
    int32_t bingus_rt1_BCryptOpenAlgorithmProvider(void **algorithm, const uint16_t *name, const uint16_t *provider,
                                                   uint32_t flags) __asm__("BCryptOpenAlgorithmProvider");
    int32_t bingus_rt1_BCryptCloseAlgorithmProvider(void *algorithm, uint32_t flags) __asm__("BCryptCloseAlgorithmProvider");
    int32_t bingus_rt1_BCryptCreateHash(void *algorithm, void **hash, void *object, uint32_t object_size,
                                        const void *secret, uint32_t secret_size, uint32_t flags) __asm__("BCryptCreateHash");
    int32_t bingus_rt1_BCryptHashData(void *hash, const void *data, uint32_t size, uint32_t flags) __asm__("BCryptHashData");
    int32_t bingus_rt1_BCryptFinishHash(void *hash, void *digest, uint32_t size, uint32_t flags) __asm__("BCryptFinishHash");
    int32_t bingus_rt1_BCryptDestroyHash(void *hash) __asm__("BCryptDestroyHash");
]]
local FUNCTIONS = {
    kernel32 = {'GetModuleHandleA', 'GetModuleFileNameW', 'GetCurrentProcess', 'ReadProcessMemory',
                'WriteProcessMemory', 'VirtualQuery', 'CreateFileW', 'ReadFile', 'CloseHandle'},
    bcrypt = {'BCryptOpenAlgorithmProvider', 'BCryptCloseAlgorithmProvider', 'BCryptCreateHash',
              'BCryptHashData', 'BCryptFinishHash', 'BCryptDestroyHash'},
}

local bound
-- {ffi, kernel32, bcrypt}, each library table holding the functions above under
-- their Windows names. Declared at most once per version in the whole game.
function runtime.native()
    if bound then return bound end
    local ffi = require('ffi')
    if not ffi.abi('64bit') then error('Windows x64 is required', 0) end
    if not pcall(ffi.typeof, 'bingus_rt1_region') then ffi.cdef(DECLARATIONS) end
    local result = {ffi = ffi}
    for library, names in pairs(FUNCTIONS) do
        local loaded, functions = ffi.load(library), {}
        for _, name in ipairs(names) do functions[name] = loaded[PREFIX .. name] end
        result[library] = functions
    end
    bound = result
    return bound
end

-- Memory -------------------------------------------------------------------------

-- MEMORY_BASIC_INFORMATION as 32-bit words: base 0-1, size 6-7, state 8,
-- protection 9, type 10. Read this way, a check allocates nothing per field.
local MEM_COMMIT, MEM_PRIVATE, PAGE_READWRITE = 0x1000, 0x20000, 4
local HIGH = 4294967296

function runtime.memory(native)
    native = native or runtime.native()
    local ffi, kernel, bcrypt = native.ffi, native.kernel32, native.bcrypt
    local process = kernel.GetCurrentProcess()
    local done = ffi.new('size_t[1]')
    local done32 = ffi.cast('uint32_t *', done)
    local region = ffi.new('bingus_rt1_region[1]')
    local words = ffi.cast('uint32_t *', region)
    local region_size = ffi.sizeof('bingus_rt1_region')
    local path = ffi.new('uint16_t[32768]')
    local scratch, scratch_size = nil, 0
    local api = {queries = 0}

    function api.module(name)
        local handle = kernel.GetModuleHandleA(name)
        if handle == nil then return nil end
        return ffi.cast('uint8_t *', handle)
    end

    -- The bytes at address as a string, or nil when they cannot all be read.
    -- Allocates only the returned string.
    function api.read(address, size)
        if size > scratch_size then
            scratch_size = max(size, scratch_size * 2, 256)
            scratch = ffi.new('uint8_t[?]', scratch_size)
        end
        if kernel.ReadProcessMemory(process, address, scratch, size, done) == 0 or done32[0] ~= size then
            return nil
        end
        return ffi.string(scratch, size)
    end

    -- Into a buffer the caller keeps: no allocation at all.
    function api.read_into(address, size, buffer)
        return kernel.ReadProcessMemory(process, address, buffer, size, done) ~= 0 and done32[0] == size
    end

    -- The user-mode pointer stored little-endian at bytes[offset+1 .. offset+8].
    function api.pointer(bytes, offset)
        offset = offset or 0
        if type(bytes) ~= 'string' or offset < 0 or offset + 8 > #bytes then return nil end
        local b1, b2, b3, b4, b5, b6, b7, b8 = bytes:byte(offset + 1, offset + 8)
        if b7 ~= 0 or b8 ~= 0 then return nil end
        local value = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216 + (b5 + b6 * 256) * HIGH
        if value < 0x10000 or value >= 0x800000000000 then return nil end
        return ffi.cast('uint8_t *', value)
    end

    function api.address(pointer)
        return tonumber(ffi.cast('uintptr_t', pointer))
    end

    function api.distance(first, second)
        return api.address(first) - api.address(second)
    end

    -- True when [address, address + size) is committed private read-write memory:
    -- never code, read-only, guard or module image pages. One VirtualQuery per region.
    function api.writable_data(address, size)
        if type(size) ~= 'number' or size <= 0 then return false end
        local cursor = api.address(address)
        local finish = cursor + size
        while cursor < finish do
            api.queries = api.queries + 1
            if tonumber(kernel.VirtualQuery(ffi.cast('const void *', cursor), region, region_size)) ~= region_size then
                return false
            end
            if words[8] ~= MEM_COMMIT or words[10] ~= MEM_PRIVATE or words[9] ~= PAGE_READWRITE then return false end
            local region_end = words[0] + words[1] * HIGH + words[6] + words[7] * HIGH
            if region_end <= cursor then return false end
            cursor = region_end
        end
        return true
    end

    -- bytes: a string, or a buffer with size. Checked right before the write.
    function api.write(address, bytes, size)
        size = size or #bytes
        if not api.writable_data(address, size) then return false end
        return kernel.WriteProcessMemory(process, address, bytes, size, done) ~= 0 and done32[0] == size
    end

    -- Several writes inside [base, base + size) with one check: changes is an
    -- array of {offset, bytes}. Stops at the first failure and returns false and
    -- how many writes landed, so the caller can undo them.
    function api.write_batch(base, size, changes)
        if not api.writable_data(base, size) then return false, 0 end
        local start = ffi.cast('uint8_t *', base)
        for index = 1, #changes do
            local offset, bytes = changes[index][1], changes[index][2]
            if offset < 0 or offset + #bytes > size
                or kernel.WriteProcessMemory(process, start + offset, bytes, #bytes, done) == 0
                or done32[0] ~= #bytes then
                return false, index - 1
            end
        end
        return true, #changes
    end

    local function sha256(name)
        local file = kernel.CreateFileW(name, 0x80000000, 7, nil, 3, 0x08000000, nil)
        if file == ffi.cast('void *', -1) then error('cannot read the module file', 0) end
        local algorithm, hash = ffi.new('void *[1]'), ffi.new('void *[1]')
        local ok, result = pcall(function()
            local id = ffi.new('uint16_t[7]', {83, 72, 65, 50, 53, 54, 0})  -- "SHA256"
            if bcrypt.BCryptOpenAlgorithmProvider(algorithm, id, nil, 0) ~= 0 then error('SHA-256 unavailable', 0) end
            if bcrypt.BCryptCreateHash(algorithm[0], hash, nil, 0, nil, 0, 0) ~= 0 then
                error('SHA-256 unavailable', 0)
            end
            local buffer, count = ffi.new('uint8_t[1048576]'), ffi.new('uint32_t[1]')
            while true do
                if kernel.ReadFile(file, buffer, 1048576, count, nil) == 0 then error('module file read failed', 0) end
                if count[0] == 0 then break end
                if bcrypt.BCryptHashData(hash[0], buffer, count[0], 0) ~= 0 then error('SHA-256 failed', 0) end
            end
            local digest, hex = ffi.new('uint8_t[32]'), {}
            if bcrypt.BCryptFinishHash(hash[0], digest, 32, 0) ~= 0 then error('SHA-256 failed', 0) end
            for i = 0, 31 do hex[i + 1] = format('%02X', digest[i]) end
            return concat(hex)
        end)
        if hash[0] ~= nil then bcrypt.BCryptDestroyHash(hash[0]) end
        if algorithm[0] ~= nil then bcrypt.BCryptCloseAlgorithmProvider(algorithm[0], 0) end
        kernel.CloseHandle(file)
        if not ok then error(result, 0) end
        return result
    end

    -- SHA-256 (uppercase hex) of a loaded module's file, read once per session
    -- for every mod: the result is kept in BingusRuntime.hashes by file path.
    function api.module_hash(module)
        local length = kernel.GetModuleFileNameW(module, path, 32768)
        if length == 0 or length >= 32768 then error('module file name unavailable', 0) end
        local shared = runtime.shared()
        local key = 'sha256:' .. ffi.string(path, length * 2)
        local cached = shared.hashes[key]
        if cached then return cached end
        local hex = sha256(path)
        shared.hash_reads = shared.hash_reads + 1
        shared.hashes[key] = hex
        return hex
    end

    -- build: {exe_sha256, game_sha256}. true, or false and why.
    function api.verify_build(build)
        local exe, game = api.module(nil), api.module('game.dll')
        if not exe or not game then return false, 'game modules unavailable' end
        if api.module_hash(exe) ~= build.exe_sha256 or api.module_hash(game) ~= build.game_sha256 then
            return false, 'unsupported game build'
        end
        return true
    end

    return api
end

-- Update guard -----------------------------------------------------------------------

-- options:
--   name    key in BingusRuntime.statuses (required, one guard per name)
--   step    function(dt, ...) before the previous update, every frame while running
--   after   function() after the previous update returned, while running
--   stop    function(reason) once, when the guard stops or the game shuts down;
--           its errors are kept in status.stop_error, never raised
--   pause   function(reason), optional: an update below this mod raised; restore
--           the game state and reset the mod to a fresh start. With it the guard
--           pauses (no step, no after) and resumes once the updates below have
--           returned on `resume` frames in a row (default 60). Without it such an
--           error stops the guard. A pause that raises stops the guard.
--   log     function(line) for the guard's few lines (errors, pauses, resumes, stop)
--   errors  errors that stop the guard (default 8), counted separately for the
--           mod's own step and after and for the updates below it. A count starts
--           again after `clean` frames without such an error (default 3600, about a
--           minute at 60 FPS), so rare transient errors never add up to a stop.
--   env     the table holding update and shutdown (default _G)
-- guard.stop(reason) stops it from the mod (a refusal counts as the first failure).
function runtime.guard(options)
    local name = options.name
    if type(name) ~= 'string' or name == '' then error('guard name required', 0) end
    local shared = runtime.shared(options.env)
    if shared.statuses[name] and shared.statuses[name].installed then error('guard ' .. name .. ' already installed', 0) end
    local status = {name = name, version = runtime.VERSION, state = 'new', installed = false, errors = 0,
        lower_errors = 0, pauses = 0}
    shared.statuses[name] = status
    local step, after_step, stop_work, pause_work, log = options.step, options.after, options.stop, options.pause,
        options.log
    local limit, resume_after, clean_after = options.errors or 8, options.resume or 60, options.clean or 3600
    local previous_update, previous_shutdown
    local in_previous, stopped, paused, failed = false, false, false, false
    local clean_run, lower_run = 0, 0

    local function note(line)
        if log then pcall(log, line) end
    end

    local function halt(reason)
        if stopped then return end
        stopped, paused = true, false
        status.first_failure = status.first_failure or reason
        status.state = 'stopped: ' .. reason
        note(name .. ' stopped: ' .. reason)
        if stop_work then
            local ok, why = pcall(stop_work, reason)
            if not ok then status.stop_error = tostring(why) end
        end
    end

    -- The mod's own step or after raised: one log line per burst of errors.
    local function failed_step(problem)
        failed, clean_run = true, 0
        status.errors = status.errors + 1
        local text = tostring(problem)
        status.first_error = status.first_error or text
        if status.errors == 1 then
            status.burst_error = text
            note(name .. ' error: ' .. text)
        end
        if status.errors >= limit then halt('stopped after ' .. limit .. ' errors: ' .. status.burst_error) end
    end

    -- An update below this mod raised (seen on the next frame).
    local function failed_below()
        lower_run = 0
        status.lower_errors = status.lower_errors + 1
        if not pause_work then return halt('the previous update failed') end
        if status.lower_errors >= limit then
            return halt('stopped after ' .. limit .. ' failed updates below this mod')
        end
        if paused then return end
        paused = true
        status.pauses = status.pauses + 1
        status.state = 'paused: the previous update failed'
        note(name .. ' paused: the previous update failed')
        local ok, why = pcall(pause_work, 'the previous update failed')
        if not ok then halt('pause failed: ' .. tostring(why)) end
    end

    local function resume_when_clean()
        if paused and lower_run >= resume_after then
            paused = false
            status.state = 'running'
            note(name .. ' resumed after ' .. resume_after .. ' clean frames')
        end
    end

    -- Counts a frame without an own error, which also clears an old burst.
    local function count_clean()
        if failed then return end
        clean_run = clean_run + 1
        if clean_run == clean_after then status.errors = 0 end
    end

    local function finish(...)
        in_previous = false
        lower_run = lower_run + 1
        if lower_run == clean_after then status.lower_errors = 0 end
        if not stopped and not paused then
            if after_step then
                local ok, problem = pcall(after_step)
                if not ok then failed_step(problem) end
            end
            count_clean()
        end
        return ...
    end

    -- The previous update runs outside pcall: its errors (value and traceback)
    -- reach the game unchanged. One that raised leaves in_previous set, and the
    -- next frame pauses (or stops) this mod and keeps forwarding.
    local function update(...)
        failed = false
        if in_previous then
            in_previous = false
            if not stopped then failed_below() end
        end
        resume_when_clean()
        if step and not stopped and not paused then
            local ok, problem = pcall(step, ...)
            if not ok then failed_step(problem) end
        end
        in_previous = true
        return finish(previous_update(...))
    end

    local function shutdown(...)
        if in_previous then
            in_previous = false
            status.first_failure = status.first_failure or 'the previous update failed'
        end
        local failure = status.first_failure
        if not stopped then
            stopped = true
            if stop_work then
                local ok, why = pcall(stop_work, 'shutdown')
                if not ok then status.stop_error = tostring(why) end
            end
        end
        status.state = failure and ('stopped after: ' .. failure) or 'stopped'
        if previous_shutdown then return previous_shutdown(...) end
    end

    local guard = {status = status}

    function guard.install()
        local env = options.env or _G
        if status.installed then error('guard ' .. name .. ' already installed', 0) end
        previous_update = rawget(env, 'update')
        if type(previous_update) ~= 'function' then error('game update unavailable', 0) end
        previous_shutdown = rawget(env, 'shutdown')
        rawset(env, 'update', update)
        rawset(env, 'shutdown', shutdown)
        status.installed, status.state = true, 'running'
        return guard
    end

    function guard.stop(reason)
        halt(tostring(reason))
    end

    function guard.running()
        return status.installed and not stopped
    end

    return guard
end

return runtime
