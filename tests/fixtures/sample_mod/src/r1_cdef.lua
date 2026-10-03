-- R1 fixture: function prototypes declared under global names. Lines marked
-- "expect: R<n>" must be reported with exactly those rules; no other line may be.
local ffi = require('ffi')
ffi.cdef [[
    typedef int (*SampleCallback)(int value);
    typedef struct { int x; } SamplePoint;
    struct SampleThing { int count; int (*visit)(int); };
    static const int SAMPLE_LIMIT = 4;
    void *GetModuleHandleA(const char *name); /* expect: R1 */
    void *sample_module(const char *name) __asm__("GetModuleHandleA");
    int GetTickCount(void) __asm__("GetTickCount"); /* expect: R1 (label repeats the name) */
    int (*sample_hook)(int value);
    int ReadProcessMemory(void *process, const void *address, /* expect: R1 */
                          void *buffer, size_t size, size_t *read);
]]
pcall(ffi.cdef, 'int WriteProcessMemory(void *p, void *a, const void *b, size_t n, size_t *w);') -- expect: R1
for _, declaration in ipairs({
    'void *GetCurrentProcess(void);', -- expect: R1
    'uint32_t sample_last_error(void) __asm__("GetLastError");',
}) do pcall(ffi.cdef, declaration) end
ffi.cdef('int CloseHandle(void *handle); /* -- lint-ok: R1 fixture: suppressed on purpose */')
local generated = make_declarations()
ffi.cdef(generated) -- expect: R1 (not a literal)
ffi.cdef 'typedef union { float f; uint32_t u; } SampleBits;'
return ffi
