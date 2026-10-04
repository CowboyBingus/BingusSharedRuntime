# Resilience tooling (layers 1 and 2)

Workspace tools that keep the mod family safe in the one LuaJIT 2.1.0-alpha state
(`bin/lua51.dll`, non-GC64) that the game shares with every mod. They use only the
Python standard library and the workspace LuaJIT. Only `runtime/bingus_runtime.lua`
ships in mods, as a byte-identical vendored copy.

| File | Purpose |
| --- | --- |
| `lint.py` | Static lint of mod sources, with a baseline that only ratchets down |
| `metrics.py` | Code-structure measurements for `lint.py` (R10-R15): cognitive complexity, function facts, active locals, duplicated code |
| `lint-repos.json` | Repos to scan: the latest published checkouts (read only), their globs and allowed globals; optional structure `limits` and `vendored` names |
| `lint-baseline.json` | Known violations: count per (repo, kind, file, rule, line text) |
| `hostile_vm.lua` | Canonical test helper; copy it byte-identical to a mod's `tests/hostile_vm.lua` |
| `runtime/bingus_runtime.lua` | Canonical shared runtime (layer 1); copy it byte-identical into a mod's `src/` |
| `tests/` | `unittest` for `lint.py`; a Lua test for `hostile_vm.lua` that runs in both VMs |

## Lint rules

| Rule | Catches | Why |
| --- | --- | --- |
| R1 `global-cdef-function` | A function prototype in `ffi.cdef` without a private `__asm__` label. Also flagged: a label that repeats the name, a cdef argument that is not a literal, and a typedef or struct tag using a shared C or Windows type name (`uint8_t`, `DWORD`, `MEMORY_BASIC_INFORMATION`, `POINT`, `struct tagPOINT`, ...; list in `SHARED_TYPE_NAMES`). Typedefs with private names are fine. | `ffi.cdef` keeps the first prototype for a name in the whole process and silently ignores later ones; a type name keeps its first layout the same way (verified in both VMs). Use `void *x_GetModuleHandleA(const char *) __asm__("GetModuleHandleA");` and `typedef struct {...} x_region;`. |
| R2 `type-string` | `ffi.cast/typeof/new/metatype` (and `sizeof/alignof/istype/offsetof`) given a string, or a local string constant, that holds a function-pointer type `(*)` or an anonymous `struct {` / `union {` / `enum {` | Each evaluation creates new C types: 3 for a function-pointer string, 2 for an anonymous struct. The 65,536-entry table never frees them. Declare a named typedef once and reuse the ctype. |
| R3 `raw-store` | A store through `ffi.cast(...)[i] = v` or `.field = v`, or through a local cast from a constant address (`local WORDS = ffi.cast('uint32_t *', 0)`) | An access violation on a stale pointer kills the game, and `pcall` cannot catch it. Stores through other pointer variables are not detected. |
| R4 `gc-mutation` | `collectgarbage` with any option except `'count'`: no argument, a variable option, or `pcall(collectgarbage, 'stop')` | It changes the GC for the game and every mod, and running out of memory in compiled code kills the game. |
| R5 `jit-global` | `jit.flush`, any use of `jit.opt` (including `require('jit.opt')` and `<x>.opt.start`), `jit.attach`, and `jit.off()`/`jit.on()` with no argument. Local aliases of `jit` count too. | Each one affects every mod's compiled code. `jit.off(fn)` with an argument is fine. |
| R6 `os-clock` | `os.clock` | It aborts trace compilation (this LuaJIT has no trace stitching) and is coarse. Time with QueryPerformanceCounter through the FFI. |
| R7 `loader-version` | A numeric comparison with the loader's `version`: tables named `*loader*`, aliases of `CowboyBingusModLoader`, or `rawget(_G, '...Loader').version`. `type(loader.version)` is fine. | The loader's internal version differs from its release number (v18 reports 17). Check capabilities instead: `loader.api`, `loader.jit`, functions. |
| R8 `global-write` (sources only) | `GSET` instructions in the compiled bytecode, plus `rawset(_G, 'x', ...)`, `_G.x =` and `_G['x'] =`. `update`, `shutdown`, `render` and the repo's `allowed_globals` are exempt. | Any other global leaks into the shared state, like CV's accidental `_`. |
| R9 `catch-previous` (sources only) | `pcall`/`xpcall` of `previous...`/`original...`, and `error((...), 0)` | Catching another layer's error and rethrowing it from the mod's frame makes vanilla errors look like mod errors. |
| R10 `cognitive-complexity` (sources only) | A function with cognitive complexity above 15 (see below) | Deeply nested branching is hard to follow and to test. The score grows with nesting, not length. Split the function into named helpers. |
| R11 `function-size` (sources only) | A function with more than 150 code lines of its own. Blank and comment-only lines do not count, nor do the bodies of nested functions, which are measured on their own. | A long function does several jobs. |
| R12 `parameters` (sources only) | A function with more than 7 parameters. `self` counts; `...` does not. | Every caller depends on the order of all of them. Pass a table. |
| R13 `luajit-limits` (sources only) | A function near one of LuaJIT's hard limits: more than 50 upvalues (limit 60), 200 stack slots (limit 250) or 180 active locals (limit 200, hidden `for` variables included). The main chunk counts too. | Past a limit the file stops compiling, so the mod does not load. Upvalues and stack slots come from the compiled bytecode. Active locals are counted from the source. |
| R14 `duplicated-code` (sources only) | A run of at least 100 tokens that also occurs elsewhere: in the same file, another file or another configured repo | A fix made in one copy misses the other. |
| R15 `module-size` (sources only) | A source file with more than 1000 code lines | A long file mixes concerns, and its main chunk heads for the 200-locals limit (R13). |

Suppression: put `-- lint-ok: R<n> <reason>` on the reported line. The reason is required. To
name several rules, write `R2,R3`. Inside a cdef string, use a C comment: `/* -- lint-ok: R1 reason */`.
R10-R12 are reported on the function's first line. R13 reports upvalues and stack slots there
too, but active locals on the line where the count peaks. R14 is reported on the first line of
the duplicated region, and R15 on the file's first line. An addon must keep that first line to
its exact `-- HD2-Addon:` declaration, so a large addon is accepted through the baseline instead.

### Structure rules (R10-R15)

`metrics.py` measures every function on its own, closures included. Upvalue and stack-slot
counts come from the same compile pass as R8 (one `F` line per prototype).

Cognitive complexity follows SonarSource's 2017 definition, adapted to Lua:
- `if`, `while`, `for` and `repeat` each add 1, plus 1 for every enclosing `if` or loop;
- `elseif`, `else` and `goto` each add 1; `break` adds nothing;
- each run of the same boolean operator adds 1, so `a and b and c` adds 1 and
  `a and b or c` adds 2. A bracket or call argument starts a run of its own and leaves the
  outer run going: `a or f(b and c) or d` adds 2;
- a function that calls itself by its local name adds 1, once.

Unlike SonarSource, a closure is not charged to the function around it. It is measured on its
own, from nesting 0.

The limits are the defaults in `metrics.LIMITS`. To change them, add a `limits` object to
`lint-repos.json`: `{"cognitive": 15, "function_lines": 150, "parameters": 7, "upvalues": 50,
"stack_slots": 200, "active_locals": 180, "module_lines": 1000, "clone_tokens": 100}`. Any key
may be left out; an unknown key stops the lint with exit code 2.

For R10-R15 the baseline stores the measured value: complexity, lines, parameters, the R13
count (locals, upvalues or stack slots) or duplicated tokens. A known function that gets worse fails `check`
(`baseline 16, now 17`), and one that improves is reported as "fixed - run update". A file above
1000 lines may not grow without review.

R14 (duplicated code) works like PMD's CPD. It compares windows of 100 tokens across every
configured repo and every `--repo` override, whatever `--only` selects, and reports regions in
the selected repos. A window that matches only overlapping windows of the same file (a long
periodic table) is not a duplicate. Files kept byte-identical on purpose are left out:
`bingus_text.lua`, `frame_budget.lua`, `hostile_vm.lua` and `bingus_runtime.lua`. A `vendored`
list in `lint-repos.json` replaces these names.

How R8 works: `luajit -bl` prints no line numbers. `lint.py` therefore compiles every source
file (it never runs them) in one workspace LuaJIT process, with `LUA_PATH` set to the LuaJIT
`src` folder. It lists each `GSET` with the same `jit.bc` module that `-bl` uses, and takes its
line from `jit.util.funcinfo`. If a file does not compile, the lint stops with exit code 2.

## Running

```
python lint.py                           # repo x rule table
python lint.py scan --list               # every violation, with its detail
python lint.py scan --json               # machine-readable output
python lint.py check                     # exit 1 when any count rose above lint-baseline.json
python lint.py update                    # rewrite the baseline after fixes; refuses increases
python lint.py update --allow-increase   # accept increases: the first baseline, or reviewed changes
```

Options:
- `--tests` also lints `tests/` (rules R1-R7).
- `--repo NAME=PATH` lints another checkout against the baseline, e.g.
  `--repo ShallowWaterDiving=publication\resilience-v1\checkouts\ShallowWaterDiving`.
  Repeat it for each repo of a release. Before the release, `check` must show no NEW line for
  those repos, or each one must be reviewed and accepted. The baseline follows the published
  checkouts. After publishing, point `lint-repos.json` at the new release checkouts and run
  `update`; accepted increases, such as a file that grew, need `--allow-increase`.
- `--only NAME` limits the scan, the check and the update to these repos.
- `--config`, `--baseline` and `--luajit` choose other files.

The baseline identity is (repo, kind, file, rule, line text with whitespace collapsed). Editing a
violating line gives it a new identity: `check` reports it as NEW and the old line as "fixed - run
update". Fix it or mark it `lint-ok`. Otherwise, after review, accept it with
`update --allow-increase`. `update` keeps entries outside the current scope: other repos when
`--only` is set, and test entries when `--tests` is not.

Exit codes: 0 means OK; 1 means new violations (`check`) or a refused update; 2 means a
configuration or compile error.

## hostile_vm.lua

Pure Lua plus FFI, in Lua 5.1 syntax. It runs in the workspace LuaJIT and in the game's
`lua51.dll`. Each function is documented at the top of the file: what game behaviour it imitates,
and why.

| Function | Imitates |
| --- | --- |
| `H.clash(names)` | A mod that loaded first and declared these names with a wrong 6-pointer prototype. Call it before anything declares them. Returns `status[name]`: `'clashed'`, `'already declared'` or `'error: ...'`. |
| `H.next_ctype()`, `H.ctype_growth(fn, ...)` | The shared 65,536-entry C type table. Returns the number of types `fn` created, excluding the probe's own 2 ids, followed by `fn`'s results. Measure a repeated call, because the first use interns array and pointer types. |
| `H.chain(env, kind [, options])`, `H.chain_restore(env)` | An abusive neighbour in the `update` chain. Kinds: `'throw_below'` (raises a table error object; `options.raise_on` takes a frame number or a function), `'drop_args'`, `'double_call'`, `'skip_odd_frames'`, `'rehook'`. Call it before the mod installs to put the neighbour below the mod, after to put it above. |
| `H.gc_hostile([pause])` | A neighbour setting the GC pause to 400. Returns a restore function. |
| `H.jit_churn()` | A full code cache or a flushing neighbour. Returns `flush()`, which calls `jit.flush()` (tests only). |
| `H.aligned16(address [, label])` | The game's `movaps` code, which faults on buffers that are not 16-byte aligned. Use it in native fakes. |
| `H.heap_peak(fn, ...)` | Returns the heap growth in KB with the GC stopped, then `fn`'s results. Use it with `H.gc_hostile` to bound a mod's allocation bursts. |

```lua
local H = dofile(tests .. '/hostile_vm.lua')
local status = H.clash({'GetModuleHandleA', 'ReadProcessMemory', 'VirtualQuery'})  -- before the mod loads
local env = {update = fake_game_update}
H.chain(env, 'throw_below', {raise_on = 3})   -- below the mod
install_mod(env)
env.update(1 / 60)                             -- warm-up frame
assert(H.ctype_growth(env.update, 1 / 60) == 0, 'C types created per frame')
```

## runtime/bingus_runtime.lua

Version 1 of the pieces every mod used to hand-roll. A mod vendors a byte-identical copy, runs it
once when it loads (the chunk returns the `runtime` table and installs nothing), and adopts it at
its next release. Copies of different versions coexist: FFI names carry the version
(`bingus_rt1_...`) and the session caches live in one global table, `BingusRuntime`
(`hashes`, `statuses`, `versions`, `hash_reads`).

- `runtime.memory()` returns the memory API:
  - `read(address, size)` (string or nil; allocates only the string), `read_into(address, size,
    buffer)` (no allocation), `pointer(bytes, offset)`, `address(pointer)`, `distance(a, b)`;
  - `write(address, bytes [, size])` and `write_batch(base, size, {{offset, bytes}, ...})`: only
    into committed private read-write memory, checked with one VirtualQuery per region right
    before the write (`api.queries` counts them);
  - `module(name)`, `module_hash(module)` (SHA-256, read once per session for every mod),
    `verify_build({exe_sha256, game_sha256})`.
- `runtime.guard{name, step, after, stop, pause, log, errors, resume, clean, env}.install()` wraps
  `update` and `shutdown`. Each step is listed below.
  - The previous update runs outside pcall (P1).
  - The first failure survives shutdown as `stopped after: <reason>` (P2).
  - Eight errors stop the mod (P3). The mod's own step and after errors are counted apart from
    updates below it that raised. Each count starts again after `clean` error-free frames
    (default 3600, about a minute at 60 FPS), so rare transient errors never add up to a stop.
    Each burst gets one log line.
  - When an update below raises, a mod that passes `pause(reason)` has its game state restored and
    is reset to a fresh start. It then skips its step until the updates below have returned on
    `resume` frames in a row (default 60), and resumes. Without `pause`, that error stops the mod
    for the session. A `pause` that raises stops it too.
  - Every argument and return passes through, and `status` lands in
    `BingusRuntime.statuses[name]` (`state`, `errors`, `lower_errors`, `pauses`).
  - `guard.stop(reason)` stops it from the mod (a refusal counts as the first failure); `stop`
    work runs once.
- `runtime.shared()` repairs a shared table that another copy or mod left incomplete, even
  `BingusRuntime = {}`, instead of failing in every adopter.
- Per frame: the step under pcall, one boolean test and two stores, one compare; no allocation,
  closure or system call (tested). A write costs one VirtualQuery per region (about 0.29 ms each in
  game).

```lua
local runtime = load_vendored('bingus_runtime')()   -- however the mod's build embeds it
local api = runtime.memory()
local ok, why = api.verify_build(build)
local guard = runtime.guard({name = 'ExampleMod', step = step, stop = restore,
                             log = function(line) log_line(line) end}).install()
if not ok then guard.stop(why) end
```

## Tests

```
python -m unittest discover -s tests -v
```

- `test_lint.py` covers every rule, the `lint-ok` comment and the baseline ratchet. In
  `tests/fixtures/sample_mod`, each expected violation is marked `expect: R<n>`, and a scan must
  report exactly the marked lines. The `r10_` to `r15_` fixtures put a function exactly at each
  limit (silent) beside one just over it (reported). The tests also check that a known function
  getting worse fails `check` and getting better reads "fixed", that limits come from the config,
  and that vendored copies are not duplicates.
- `test_metrics.py` checks cognitive complexity against SonarSource's examples (`sum_of_primes`
  scores 7), boolean runs, nesting, recursion and closures. It also checks LuaJIT's local count,
  hidden `for` variables included, and duplicated-code regions. Eight deliberate bugs in
  `metrics.py` and `lint.py` are all caught.
- `test_runtime.py` runs `tests/test_runtime.lua` in both VMs: clashing Windows
  prototypes declared first, two runtime copies, C-type growth and allocation per call and per
  frame, write checks against read-only, executable, image and split regions, the session hash
  cache, and the guard against hostile neighbours (`throw_below`, `double_call`, `drop_args`,
  `rehook`). Nine mutations of the runtime are all caught in both VMs.
- `test_hostile_vm.py` runs `tests/test_hostile_vm.lua` twice: in the workspace LuaJIT, and in the
  installed game's `lua51.dll` through `PerformanceBaseline/game_lua.py`. The game is never
  started.
