"""Code structure metrics for lint.py: complexity, size, LuaJIT limits and duplicated code.

Works on lint.py's tokens (Python standard library only). Per function:

- Cognitive complexity, after SonarSource's definition (2017) adapted to Lua: +1 and +nesting
  for `if`, `while`, `for` and `repeat`; +1 for `elseif`, `else` and `goto`; +1 for each run of
  like `and`/`or` operators (a change of operator starts a new run; brackets nest runs); +1 when
  the function calls itself by name. Every function, closures included, is measured on its own,
  so a module factory is not charged with the functions it defines.
- Code lines (lines holding one of its own tokens: a nested function's body counts for that
  function, and only the line it starts on for both), parameters, and the most local variables
  active at once (parameters, locals and the hidden `for` variables): the count LuaJIT limits to
  200 per function.

Exact numbers from LuaJIT's own compiler (upvalues, stack slots) come from lint.py's bytecode
lister and are joined to these by the function's first line.

Duplicated code: windows of `clone_tokens` tokens that occur more than once across the scanned
files, merged into regions.
"""
from __future__ import annotations

from dataclasses import dataclass, field

LIMITS = {
    'cognitive': 15,        # SonarSource's default for a function
    'function_lines': 150,  # a function's own code lines (nested functions are measured on their own)
    'parameters': 7,        # SonarSource's default
    'upvalues': 50,         # LuaJIT allows 60 per function
    'stack_slots': 200,     # LuaJIT allows 250 per function
    'active_locals': 180,   # LuaJIT allows 200 per function
    'module_lines': 1000,   # SonarSource's default for a file
    'clone_tokens': 100,    # duplicated block length (PMD CPD's default)
}

CONTROL = frozenset(('if', 'while', 'for', 'repeat'))
# Operators and keywords that continue a boolean expression; anything else ends the current run.
EXPRESSION_OPS = frozenset(('+', '-', '*', '/', '%', '^', '#', '..', '==', '~=', '<', '>', '<=', '>=',
                            '.', ':', '...'))
EXPRESSION_KEYWORDS = frozenset(('not', 'nil', 'true', 'false', 'and', 'or'))
OPENING, CLOSING = frozenset(('(', '[', '{')), frozenset((')', ']', '}'))


@dataclass
class Function:
    name: str
    line: int                 # line of the `function` keyword (1 for the main chunk)
    end: int = 0
    parameters: int = 0       # including `self` for a method; `...` not counted
    vararg: bool = False
    cognitive: int = 0
    nesting: int = 0          # deepest control nesting inside this function
    active_locals: int = 0    # most locals in scope at once (parameters included)
    active_line: int = 0      # where that maximum was reached
    lines: set = field(default_factory=set)
    calls_itself: bool = False


class _Frame:
    """Parser state for one open function."""

    def __init__(self, function: Function):
        self.function = function
        self.blocks: list[str] = []           # open blocks: if, loop, repeat, do
        self.scopes: list[int] = [0]          # locals declared per open scope
        self.runs: list[str | None] = [None]  # last and/or per bracket level

    def control_depth(self) -> int:
        return sum(1 for block in self.blocks if block != 'do')

    def declare(self, count: int, line: int) -> None:
        self.scopes[-1] += count
        active = sum(self.scopes)
        if active > self.function.active_locals:
            self.function.active_locals, self.function.active_line = active, line

    def open_block(self, block: str) -> None:
        self.blocks.append(block)
        self.scopes.append(0)


class _End:
    kind, value, line = 'eof', '', 0


_END = _End()


def _at(tokens, index: int):
    """The token at index, or an end marker past either end (lint.tokenize adds none)."""
    return tokens[index] if 0 <= index < len(tokens) else _END


def _is(token, kind: str, *values: str) -> bool:
    return token.kind == kind and (not values or token.value in values)


def _function_header(tokens, index: int) -> tuple[str, int, int, bool]:
    """(name, index after the parameter list, parameters, vararg) for the keyword at index."""
    k, parts, method = index + 1, [], False
    if _is(_at(tokens, k), 'name'):                          # function a.b:c (...)
        parts.append(_at(tokens, k).value)
        k += 1
        while _is(_at(tokens, k), 'op', '.', ':') and _is(_at(tokens, k + 1), 'name'):
            method = _at(tokens, k).value == ':'
            parts.append(_at(tokens, k + 1).value)
            k += 2
    elif index >= 2 and _is(_at(tokens, index - 1), 'op', '=') and _is(_at(tokens, index - 2), 'name'):
        parts.append(_at(tokens, index - 2).value)           # name = function, t.name = function
    params, vararg = (1 if method else 0), False
    if _is(_at(tokens, k), 'op', '('):
        k += 1
        while not _is(_at(tokens, k), 'op', ')') and _at(tokens, k).kind != 'eof':
            if _at(tokens, k).kind == 'name':
                params += 1
            elif _is(_at(tokens, k), 'op', '...'):
                vararg = True
            k += 1
        k += 1
    return '.'.join(parts) or '<anonymous>', k, params, vararg


def _local_count(tokens, k: int) -> int:
    """Names declared by the `local` keyword at k (`local function f` declares one)."""
    j = k + 1
    if _is(_at(tokens, j), 'keyword', 'function'):
        return 1
    count = 0
    while _at(tokens, j).kind == 'name':
        count += 1
        j += 1
        if not _is(_at(tokens, j), 'op', ','):
            break
        j += 1
    return count


class _Parser:
    def __init__(self, tokens):
        self.tokens = tokens
        self.main = Function('<main chunk>', 1)
        self.functions: list[Function] = []
        self.frames = [_Frame(self.main)]
        self.pending_do = 0            # `while`/`for` headers waiting for their `do`
        self.for_names: int | None = None  # loop variables of the `for` header being read
        self.for_counting = False      # still before the header's `=` or `in`

    def run(self) -> None:
        k = 0
        while k < len(self.tokens) and _at(self.tokens, k).kind != 'eof':
            token = _at(self.tokens, k)
            frame = self.frames[-1]
            if token.line:
                frame.function.lines.add(token.line)
            if _is(token, 'keyword', 'function'):
                k = self.enter_function(k)
                continue
            if token.kind == 'keyword':
                self.keyword(frame, k)
            elif token.kind == 'name':
                self.name(frame, k)
            elif token.kind == 'op':
                self.operator(frame, token.value)
            k += 1
        self.main.end = _at(self.tokens, k - 1).line if k else 1

    def enter_function(self, k: int) -> int:
        name, after, params, vararg = _function_header(self.tokens, k)
        record = Function(name, _at(self.tokens, k).line, parameters=params, vararg=vararg)
        for index in range(k, after):
            if _at(self.tokens, index).line:
                record.lines.add(_at(self.tokens, index).line)
        self.functions.append(record)
        frame = _Frame(record)
        frame.declare(params + (1 if vararg else 0), record.line)
        self.frames.append(frame)
        return after

    def keyword(self, frame: _Frame, k: int) -> None:
        value, function, line = _at(self.tokens, k).value, frame.function, _at(self.tokens, k).line
        if value in CONTROL:
            function.cognitive += 1 + frame.control_depth()
            frame.open_block('if' if value == 'if' else 'repeat' if value == 'repeat' else 'loop')
            function.nesting = max(function.nesting, frame.control_depth())
            if value in ('while', 'for'):
                self.pending_do += 1
            if value == 'for':
                self.for_names, self.for_counting = 0, True
        elif value in ('elseif', 'else'):
            function.cognitive += 1
            frame.scopes[-1] = 0          # a new branch: the previous branch's locals are gone
        elif value == 'do':
            self.do(frame, line)
        elif value in ('end', 'until'):
            self.close(frame, line)
        elif value == 'goto':
            function.cognitive += 1
        elif value == 'local':
            frame.declare(_local_count(self.tokens, k), line)
        elif value == 'in':
            self.for_counting = False
        self.boolean_run(frame, value)

    def do(self, frame: _Frame, line: int) -> None:
        if not self.pending_do:
            frame.open_block('do')
            return
        self.pending_do -= 1
        if self.for_names is not None:
            frame.declare(3 + self.for_names, line)  # LuaJIT's 3 hidden control variables, then the names
            self.for_names, self.for_counting = None, False

    def close(self, frame: _Frame, line: int) -> None:
        if frame.blocks:
            frame.blocks.pop()
            frame.scopes.pop()
        else:                                # the function's own end
            frame.function.end = line
            self.frames.pop()

    def boolean_run(self, frame: _Frame, value: str) -> None:
        if value in ('and', 'or'):
            if frame.runs[-1] != value:
                frame.function.cognitive += 1
            frame.runs[-1] = value
        elif value not in EXPRESSION_KEYWORDS:
            frame.runs[-1] = None

    def name(self, frame: _Frame, k: int) -> None:
        if self.for_counting:
            self.for_names += 1
        function = frame.function
        own = function.name.split('.')[-1]
        if (not function.calls_itself and function is not self.main and _at(self.tokens, k).value == own
                and _is(_at(self.tokens, k + 1), 'op', '(') and not _is(_at(self.tokens, k - 1), 'op', '.', ':')):
            function.calls_itself = True
            function.cognitive += 1

    def operator(self, frame: _Frame, value: str) -> None:
        if value == '=':
            self.for_counting = False     # numeric for: only the name before '='
        if value in OPENING:
            frame.runs.append(None)
        elif value in CLOSING:
            if len(frame.runs) > 1:
                frame.runs.pop()
        elif value not in EXPRESSION_OPS:
            frame.runs[-1] = None


def analyse(tokens) -> tuple[Function, list[Function]]:
    """(main chunk, every function in source order) for one file's tokens."""
    parser = _Parser(tokens)
    parser.run()
    return parser.main, parser.functions


# ----------------------------------------------------------------------------- duplicated code

@dataclass
class Clone:
    file: int          # index into the files list
    start: int         # first token index
    end: int           # one past the last token index
    other_file: int    # the first other occurrence
    other_start: int


def duplicates(files: list[list], length: int) -> list[Clone]:
    """Regions of at least `length` tokens that also occur elsewhere (another file, or a
    non-overlapping place in the same file). files: token lists without eof. One Clone per
    maximal region and file, naming the first other occurrence found."""
    ids: dict[tuple[str, str], int] = {}
    sequences = [[ids.setdefault((t.kind, t.value), len(ids)) + 1 for t in tokens] for tokens in files]
    base, modulus = 1_000_003, (1 << 61) - 1
    power = pow(base, length - 1, modulus)
    buckets: dict[int, list[tuple[int, int]]] = {}
    for f, sequence in enumerate(sequences):
        if len(sequence) < length:
            continue
        value = 0
        for item in sequence[:length]:
            value = (value * base + item) % modulus
        buckets.setdefault(value, []).append((f, 0))
        for start in range(1, len(sequence) - length + 1):
            value = ((value - sequence[start - 1] * power) * base + sequence[start + length - 1]) % modulus
            buckets.setdefault(value, []).append((f, start))
    covered: list[dict[int, tuple[int, int]]] = [{} for _ in files]
    for places in buckets.values():
        if len(places) < 2:
            continue
        groups: dict[tuple, list[tuple[int, int]]] = {}
        for f, start in places:                      # hash collisions: group by content
            groups.setdefault(tuple(sequences[f][start:start + length]), []).append((f, start))
        for group in groups.values():
            for f, start in group:
                other = next((p for p in group if p[0] != f or abs(p[1] - start) >= length), None)
                if other is not None:
                    for position in range(start, start + length):
                        covered[f].setdefault(position, other)
    clones = []
    for f, positions in enumerate(covered):
        ordered = sorted(positions)
        start = 0
        for index in range(1, len(ordered) + 1):
            if index == len(ordered) or ordered[index] != ordered[index - 1] + 1:
                first = ordered[start]
                other = positions[first]
                clones.append(Clone(f, first, ordered[index - 1] + 1, other[0], other[1]))
                start = index
    return clones
