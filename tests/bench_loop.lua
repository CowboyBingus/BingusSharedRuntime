-- Compiled code and cost of a typical guarded mod loop on the runtime: per frame
-- the clock, three reads into kept buffers and one string read before the update
-- below; with `check`, also one page check. Prints the traces and machine code
-- the loop compiled, its garbage per frame (compiled and interpreted) and its time
-- per frame in this process. Test-process times are not in-game times: system
-- calls cost far more in the game, so compare builds, never quote these as ms
-- per frame. Not part of the unit tests; run it when a change could alter
-- compiled code:
--   python -B game_lua.py tests/bench_loop.lua runtime hostile_vm.lua [reads|check]
--   luajit tests/bench_loop.lua runtime hostile_vm.lua [reads|check]
local folder, helper, variant = assert(arg[1]), assert(arg[2]), arg[3] or 'reads'
local ffi = require('ffi')
local util = require('jit.util')
local H = dofile(helper)
ffi.cdef [[
    void *bench_VirtualAlloc(void *address, size_t size, uint32_t type, uint32_t protection) __asm__("VirtualAlloc");
    int bench_VirtualFree(void *address, size_t size, uint32_t type) __asm__("VirtualFree");
]]
local kernel = ffi.load('kernel32')

local runtime = dofile(folder .. '/bingus_runtime.lua')
local api = dofile(folder .. '/bingus_memory.lua').new(runtime)
dofile(folder .. '/bingus_write.lua').extend(api)

local block = kernel.bench_VirtualAlloc(nil, 4096, 0x3000, 4)
assert(block ~= nil, 'allocation failed')
local data = ffi.cast('uint8_t *', block)
for i = 0, 255 do data[i] = i end
local a, b, c, d = data, data + 64, data + 128, data + 256
local header, record, word = ffi.new('uint8_t[16]'), ffi.new('uint8_t[64]'), ffi.new('uint8_t[8]')
local state, check_pages = {last = 0, sum = 0}, variant == 'check'

local function step()
    local now = api.time()
    if now < state.last then error('the clock went back') end
    state.last = now
    if api.read_into(a, 16, header) and api.read_into(b, 64, record) and api.read_into(c, 8, word) then
        state.sum = state.sum + header[1] + record[2] + word[3]
    end
    local bytes = api.read(d, 8)
    if bytes and #bytes == 8 then state.sum = state.sum + 1 end
    if check_pages and api.writable_data(b, 64) then state.sum = state.sum + 1 end
end
local game = {update = function() end}
runtime.guard({name = 'bench', env = game, step = step, after = function() end}).install()
local function frames(n) for _ = 1, n do game.update(1 / 60) end end

-- Traces compiled while the loop runs, by the file each trace starts in.
local per_file, traces, aborts, started = {}, 0, 0, {}
local flush = H.jit_churn()
flush()
local function on_trace(what, trace, func)
    if what == 'start' then
        started[trace] = ((util.funcinfo(func).source or '?'):gsub(string.char(92), '/')):match('[^/]*$')
    elseif what == 'stop' then
        local code = util.tracemc(trace)
        local file = started[trace] or '?'
        per_file[file] = (per_file[file] or 0) + (code and #code or 0)
        traces = traces + 1
    elseif what == 'abort' then
        aborts = aborts + 1
    end
end
jit.attach(on_trace, 'trace') -- lint-ok: R5 benchmark only: counts the traces this loop compiles
frames(20000)
jit.attach(on_trace) -- lint-ok: R5 benchmark only: detaches the handler
local total, files = 0, {}
for file, bytes in pairs(per_file) do
    total = total + bytes
    files[#files + 1] = file .. ' ' .. bytes .. ' B'
end
table.sort(files)

ffi.cdef [[
    int bench_QueryPerformanceCounter(int64_t *count) __asm__("QueryPerformanceCounter");
    int bench_QueryPerformanceFrequency(int64_t *frequency) __asm__("QueryPerformanceFrequency");
]]
local count, frequency = ffi.new('int64_t[1]'), ffi.new('int64_t[1]')
kernel.bench_QueryPerformanceFrequency(frequency)
local function seconds()
    kernel.bench_QueryPerformanceCounter(count)
    return tonumber(count[0]) / tonumber(frequency[0])
end
local compiled_garbage = H.heap_peak(frames, 50000) * 1024 / 50000
local start = seconds()
frames(100000)
local compiled_us = (seconds() - start) / 100000 * 1e6
flush()
jit.off() -- lint-ok: R5 benchmark only: the interpreted case
frames(200)
local interpreted_garbage = H.heap_peak(frames, 50000) * 1024 / 50000
start = seconds()
frames(20000)
local interpreted_us = (seconds() - start) / 20000 * 1e6
jit.on() -- lint-ok: R5 benchmark only
kernel.bench_VirtualFree(block, 0, 0x8000)

print(string.format('%s: %d traces, %d aborts, machine code %d B (%s); garbage %.1f B/frame compiled, '
    .. '%.1f B/frame interpreted; %.2f us/frame compiled, %.2f us/frame interpreted (this process, not the game) [%s]',
    variant, traces, aborts, total, table.concat(files, ', '), compiled_garbage, interpreted_garbage, compiled_us,
    interpreted_us, jit.version))
