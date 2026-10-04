-- The runtime in a hostile VM: another mod loaded first and declared every
-- Windows function the runtime uses under its plain name. ffi.cdef keeps that
-- first prototype for the whole game, so a runtime calling plain names would get
-- the other mod's prototypes. Two neighbours, one per run (a VM keeps the first
-- declaration of a name for good):
--   sdk    declarations copied from the Windows SDK headers (DWORD, HANDLE,
--          LARGE_INTEGER, MEMORY_BASIC_INFORMATION, ...): plausible and different
--          from the runtime's own. Both the runtime and the neighbour must work.
--   clash  hostile_vm.lua's H.clash: a wrong 6-pointer prototype for every name.
-- Run by tests/test_runtime.py in a LuaJIT executable and in the game's lua51.dll.
-- arg[1] the runtime folder, arg[2] hostile_vm.lua, arg[3] sdk or clash, arg[4] SHA-256 of this
-- process's executable.
local folder, helper_path, mode, exe_sha256 = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4])
local ffi = require('ffi')
local H = dofile(helper_path)

local passed = 0
local function check(name, condition, detail)
    if not condition then error(name .. (detail ~= nil and (': ' .. tostring(detail)) or ''), 2) end
    passed = passed + 1
end

local NAMES = {'GetModuleHandleA', 'GetModuleFileNameW', 'GetCurrentProcess', 'ReadProcessMemory',
               'WriteProcessMemory', 'VirtualQuery', 'QueryPerformanceCounter', 'QueryPerformanceFrequency',
               'CreateFileW', 'ReadFile', 'CloseHandle', 'BCryptOpenAlgorithmProvider', 'BCryptCloseAlgorithmProvider',
               'BCryptCreateHash', 'BCryptHashData', 'BCryptFinishHash', 'BCryptDestroyHash'}

local SDK = [[
    typedef unsigned long DWORD;
    typedef int BOOL;
    typedef unsigned short WORD;
    typedef void *HANDLE;
    typedef HANDLE HMODULE;
    typedef void *LPVOID;
    typedef const void *LPCVOID;
    typedef const char *LPCSTR;
    typedef wchar_t *LPWSTR;
    typedef const wchar_t *LPCWSTR;
    typedef size_t SIZE_T;
    typedef long LONG;
    typedef long long LONGLONG;
    typedef long NTSTATUS;
    typedef void *BCRYPT_ALG_HANDLE;
    typedef void *BCRYPT_HASH_HANDLE;
    typedef union _LARGE_INTEGER {
        struct { DWORD LowPart; LONG HighPart; };
        LONGLONG QuadPart;
    } LARGE_INTEGER;
    typedef struct _MEMORY_BASIC_INFORMATION {
        LPVOID BaseAddress; LPVOID AllocationBase; DWORD AllocationProtect; WORD PartitionId;
        SIZE_T RegionSize; DWORD State; DWORD Protect; DWORD Type;
    } MEMORY_BASIC_INFORMATION, *PMEMORY_BASIC_INFORMATION;
    typedef struct _SECURITY_ATTRIBUTES { DWORD nLength; LPVOID lpSecurityDescriptor; BOOL bInheritHandle; } SECURITY_ATTRIBUTES;
    HMODULE GetModuleHandleA(LPCSTR lpModuleName);
    DWORD GetModuleFileNameW(HMODULE hModule, LPWSTR lpFilename, DWORD nSize);
    HANDLE GetCurrentProcess(void);
    BOOL ReadProcessMemory(HANDLE hProcess, LPCVOID lpBaseAddress, LPVOID lpBuffer, SIZE_T nSize, SIZE_T *lpNumberOfBytesRead);
    BOOL WriteProcessMemory(HANDLE hProcess, LPVOID lpBaseAddress, LPCVOID lpBuffer, SIZE_T nSize, SIZE_T *lpNumberOfBytesWritten);
    SIZE_T VirtualQuery(LPCVOID lpAddress, PMEMORY_BASIC_INFORMATION lpBuffer, SIZE_T dwLength);
    BOOL QueryPerformanceCounter(LARGE_INTEGER *lpPerformanceCount);
    BOOL QueryPerformanceFrequency(LARGE_INTEGER *lpFrequency);
    HANDLE CreateFileW(LPCWSTR lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode, SECURITY_ATTRIBUTES *lpSecurityAttributes,
                       DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes, HANDLE hTemplateFile);
    BOOL ReadFile(HANDLE hFile, LPVOID lpBuffer, DWORD nNumberOfBytesToRead, DWORD *lpNumberOfBytesRead, LPVOID lpOverlapped);
    BOOL CloseHandle(HANDLE hObject);
    NTSTATUS BCryptOpenAlgorithmProvider(BCRYPT_ALG_HANDLE *phAlgorithm, LPCWSTR pszAlgId, LPCWSTR pszImplementation, DWORD dwFlags);
    NTSTATUS BCryptCloseAlgorithmProvider(BCRYPT_ALG_HANDLE hAlgorithm, DWORD dwFlags);
    NTSTATUS BCryptCreateHash(BCRYPT_ALG_HANDLE hAlgorithm, BCRYPT_HASH_HANDLE *phHash, unsigned char *pbHashObject,
                              DWORD cbHashObject, unsigned char *pbSecret, DWORD cbSecret, DWORD dwFlags);
    NTSTATUS BCryptHashData(BCRYPT_HASH_HANDLE hHash, unsigned char *pbInput, DWORD cbInput, DWORD dwFlags);
    NTSTATUS BCryptFinishHash(BCRYPT_HASH_HANDLE hHash, unsigned char *pbOutput, DWORD cbOutput, DWORD dwFlags);
    NTSTATUS BCryptDestroyHash(BCRYPT_HASH_HANDLE hHash);
]]

-- 1. The neighbour declares first -------------------------------------------------------------------

if mode == 'sdk' then
    ffi.cdef(SDK)
elseif mode == 'clash' then
    local status = H.clash(NAMES)
    for _, name in ipairs(NAMES) do check('clashed ' .. name, status[name] == 'clashed', status[name]) end
    check('a plain call now fails', not pcall(function() return ffi.C.GetModuleHandleA(nil) end))
else
    error('mode: sdk or clash, got ' .. tostring(mode))
end

-- 2. The runtime loads and works -----------------------------------------------------------------------

local runtime = dofile(folder .. '/bingus_runtime.lua')
local api = dofile(folder .. '/bingus_memory.lua').new(runtime)
dofile(folder .. '/bingus_write.lua').extend(api)
local reader = dofile(folder .. '/bingus_memory.lua').new(runtime)

ffi.cdef [[
    void *rth_VirtualAlloc(void *address, size_t size, uint32_t type, uint32_t protection) __asm__("VirtualAlloc");
    int rth_VirtualProtect(void *address, size_t size, uint32_t protection, uint32_t *old) __asm__("VirtualProtect");
    int rth_VirtualFree(void *address, size_t size, uint32_t type) __asm__("VirtualFree");
]]
local kernel = ffi.load('kernel32')
local PAGE = 4096
local data = ffi.cast('uint8_t *', kernel.rth_VirtualAlloc(nil, 2 * PAGE, 0x3000, 4))
check('allocation', data ~= nil)
for i = 0, 255 do data[i] = i end
kernel.rth_VirtualProtect(data + PAGE, PAGE, 2, ffi.new('uint32_t[1]'))

local into = ffi.new('uint8_t[8]')
check('read', api.read(data + 1, 3) == '\1\2\3' and reader.read(data, 2) == '\0\1')
check('read_into', api.read_into(data + 8, 8, into) and into[0] == 8 and into[7] == 15)
check('page check', api.writable_data(data, PAGE) and not api.writable_data(data + PAGE, 1)
    and not api.writable_data(api.module(nil), 1))
check('write', api.write(data + 32, '\7\7') and data[32] == 7 and data[33] == 7)
check('a refused write', not api.write(data + PAGE, '\1') and data[PAGE] == 0)
local ok, count = api.write_batch(data, 64, {{0, '\9'}, {63, '\9'}})
check('write_batch', ok and count == 2 and data[0] == 9 and data[63] == 9)
local t0 = api.time()
check('time', type(t0) == 'number' and t0 > 0 and api.time() >= t0)
check('module hash', api.module_hash(api.module(nil)) == exe_sha256)
local verified, why = api.verify_build({exe_sha256 = exe_sha256, game_sha256 = 'x'})
check('verify_build answers', not verified and why == 'game modules unavailable', why)

do -- under churn: a hostile GC pause and JIT flushes between calls
    local restore, flush = H.gc_hostile(), H.jit_churn()
    local fine = true
    for round = 1, 3 do
        flush()
        for _ = 1, 5000 do
            fine = fine and api.read_into(data, 8, into) and api.writable_data(data, 8) and api.time() > 0
        end
        fine = fine and api.write(data + 100, string.char(round)) and data[100] == round
    end
    restore()
    check('reads, checks, writes and time across flushes', fine)
end

-- 3. The neighbour still works with its own declarations ----------------------------------------------

if mode == 'sdk' then
    local counter = ffi.new('LARGE_INTEGER[1]')
    check('the neighbour\'s QueryPerformanceCounter', ffi.C.QueryPerformanceCounter(counter) ~= 0
        and counter[0].QuadPart > 0)
    local info = ffi.new('MEMORY_BASIC_INFORMATION[1]')
    check('the neighbour\'s VirtualQuery', tonumber(ffi.C.VirtualQuery(data, info, ffi.sizeof(info))) == ffi.sizeof(info)
        and info[0].State == 0x1000 and info[0].Protect == 4)
    local done = ffi.new('SIZE_T[1]')
    check('the neighbour\'s WriteProcessMemory', ffi.C.WriteProcessMemory(ffi.C.GetCurrentProcess(), data + 200, '\5', 1,
        done) ~= 0 and data[200] == 5)
    check('the neighbour\'s GetModuleHandleA', ffi.C.GetModuleHandleA(nil) ~= nil)
end

kernel.rth_VirtualFree(data, 0, 0x8000)

print('runtime in a hostile VM (' .. mode .. '): ' .. passed .. ' checks passed (' .. jit.version .. ')')
