"""Resilience lint for the Bingus Helldivers 2 Lua mods (Python standard library only).

Every mod shares one LuaJIT 2.1.0-alpha state with the game and with other mods.
This lint finds code that is unsafe in that shared state and keeps a baseline of
known violations that may only ratchet down.

  python lint.py [scan] [--list] [--json]    report violations (repo x rule table)
  python lint.py check                       exit 1 when a violation count rose above the baseline
  python lint.py update [--allow-increase]   rewrite the baseline from the current scan

Common options:
  --tests             also scan test files (rules R1-R7 only)
  --repo NAME=PATH    lint another checkout of NAME (e.g. a working branch) against the baseline
  --only NAME         limit the scan, the check and the update to these repos
  --config, --baseline, --luajit   alternative files

Rules (see README.md): R1 global-cdef-function, R2 type-string, R3 raw-store, R4 gc-mutation,
R5 jit-global, R6 os-clock, R7 loader-version, R8 global-write, R9 catch-previous; structure
(sources only, measured by metrics.py): R10 cognitive-complexity, R11 function-size,
R12 parameters, R13 luajit-limits, R14 duplicated-code, R15 module-size.
A source line containing `-- lint-ok: R<n> <reason>` suppresses rule R<n> on that line; for a
structure rule, put it on the function's first line (R15: the file's first line).
For R10-R15 the baseline holds the measured value (complexity, lines, parameters, the limit
counter, duplicated tokens), so a function that gets worse fails `check` too.

Exit codes: 0 fine, 1 new violations (check) or refused update, 2 configuration or compile error.
"""
from __future__ import annotations

import argparse
import bisect
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

import metrics

HERE = Path(__file__).resolve().parent
DEFAULT_CONFIG = HERE / 'lint-repos.json'
DEFAULT_BASELINE = HERE / 'lint-baseline.json'

RULES = {
    'R1': 'global-cdef-function',
    'R2': 'type-string',
    'R3': 'raw-store',
    'R4': 'gc-mutation',
    'R5': 'jit-global',
    'R6': 'os-clock',
    'R7': 'loader-version',
    'R8': 'global-write',
    'R9': 'catch-previous',
    'R10': 'cognitive-complexity',
    'R11': 'function-size',
    'R12': 'parameters',
    'R13': 'luajit-limits',
    'R14': 'duplicated-code',
    'R15': 'module-size',
}
STRUCTURE_RULES = frozenset(('R10', 'R11', 'R12', 'R13', 'R14', 'R15'))
# Files kept byte-identical to a canonical copy on purpose (sync tools check them): R14 skips them.
DEFAULT_VENDORED = ('bingus_text.lua', 'frame_budget.lua', 'hostile_vm.lua', 'bingus_runtime.lua')
TEST_RULES = frozenset(('R1', 'R2', 'R3', 'R4', 'R5', 'R6', 'R7'))
DEFAULT_ALLOWED_GLOBALS = ('update', 'shutdown', 'render')
DEFAULT_SOURCES = ('src/**/*.lua',)
DEFAULT_TESTS = ('tests/**/*.lua',)


class LintError(Exception):
    """A file that cannot be scanned, or a bad configuration: the lint cannot give an answer."""


# ----------------------------------------------------------------------------- Lua lexer

KEYWORDS = frozenset(('and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function',
                      'goto', 'if', 'in', 'local', 'nil', 'not', 'or', 'repeat', 'return', 'then',
                      'true', 'until', 'while'))
NAME_RE = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
NUMBER_RE = re.compile(r'(?:0[xX][0-9A-Fa-f]*(?:\.[0-9A-Fa-f]*)?(?:[pP][+-]?[0-9]+)?'
                       r'|[0-9]+(?:\.[0-9]*)?(?:[eE][+-]?[0-9]+)?'
                       r'|\.[0-9]+(?:[eE][+-]?[0-9]+)?)'
                       r'(?:[uU]?[lL][lL]|[iI])?')
LONG_BRACKET_RE = re.compile(r'\[(=*)\[')
OPERATORS = ('...', '..', '==', '~=', '<=', '>=', '::', '<<', '>>', '//')
DIGITS = '0123456789'
ESCAPES = {'a': '\a', 'b': '\b', 'f': '\f', 'n': '\n', 'r': '\r', 't': '\t', 'v': '\v',
           '\\': '\\', '"': '"', "'": "'", '\n': '\n'}


@dataclass(frozen=True)
class Token:
    kind: str          # name, keyword, string, number, op, eof
    value: str         # identifier, decoded string, number text or operator
    line: int          # line of the first character
    content: int = -1  # long strings only: offset of the first character of the string's value


EOF = Token('eof', '', 0)


def _short_string(text: str, start: int, line: int) -> tuple[str, int, int]:
    """Decodes the quoted string at text[start]; returns (value, end offset, newlines inside)."""
    quote, out, newlines, i, n = text[start], [], 0, start + 1, len(text)
    while i < n:
        c = text[i]
        if c == quote:
            return ''.join(out), i + 1, newlines
        if c == '\n':
            break
        if c != '\\':
            out.append(c)
            i += 1
            continue
        i += 1
        e = text[i] if i < n else ''
        try:
            if e in ESCAPES:
                out.append(ESCAPES[e])
                newlines += e == '\n'
                i += 1
            elif e == 'z':
                i += 1
                while i < n and text[i] in ' \t\n\f\v':
                    newlines += text[i] == '\n'
                    i += 1
            elif e == 'x':
                out.append(chr(int(text[i + 1:i + 3], 16)))
                i += 3
            elif e == 'u':
                close = text.index('}', i)
                out.append(chr(int(text[i + 2:close], 16)))
                i = close + 1
            elif e.isdigit():
                digits = re.match(r'[0-9]{1,3}', text[i:i + 3]).group()
                out.append(chr(int(digits)))
                i += len(digits)
            else:
                raise ValueError(f'invalid escape \\{e}')
        except ValueError as problem:
            raise LintError(f'line {line}: {problem}') from None
    raise LintError(f'line {line}: unfinished string')


def tokenize(text: str) -> list[Token]:
    """Splits Lua source (newlines already normalised to \\n) into tokens, dropping comments."""
    tokens: list[Token] = []
    i, n, line = 0, len(text), 1
    if text.startswith('#'):  # shebang line: loadfile skips it
        i = text.find('\n')
        i = n if i < 0 else i
    while i < n:
        c = text[i]
        if c == '\n':
            line += 1
            i += 1
        elif c in ' \t\r\f\v':
            i += 1
        elif text.startswith('--', i):
            bracket = LONG_BRACKET_RE.match(text, i + 2)
            if bracket:
                close = ']' + bracket.group(1) + ']'
                end = text.find(close, bracket.end())
                if end < 0:
                    raise LintError(f'line {line}: unfinished long comment')
                end += len(close)
            else:
                end = text.find('\n', i)
                end = n if end < 0 else end
            line += text.count('\n', i, end)
            i = end
        elif c == '[' and LONG_BRACKET_RE.match(text, i):
            bracket = LONG_BRACKET_RE.match(text, i)
            close = ']' + bracket.group(1) + ']'
            end = text.find(close, bracket.end())
            if end < 0:
                raise LintError(f'line {line}: unfinished long string')
            start = bracket.end()
            if start < n and text[start] == '\n':  # the first newline is not part of the value
                start += 1
            tokens.append(Token('string', text[start:end], line, start))
            line += text.count('\n', i, end + len(close))
            i = end + len(close)
        elif c in '"\'':
            value, end, newlines = _short_string(text, i, line)
            tokens.append(Token('string', value, line))
            line += newlines
            i = end
        elif c in DIGITS or (c == '.' and i + 1 < n and text[i + 1] in DIGITS):
            number = NUMBER_RE.match(text, i)
            tokens.append(Token('number', number.group(), line))
            i = number.end()
        elif NAME_RE.match(text, i):
            name = NAME_RE.match(text, i).group()
            tokens.append(Token('keyword' if name in KEYWORDS else 'name', name, line))
            i += len(name)
        else:
            op = next((o for o in OPERATORS if text.startswith(o, i)), c)
            tokens.append(Token('op', op, line))
            i += len(op)
    return tokens


class Source:
    """One Lua file: its lines, tokens and matching brackets."""

    def __init__(self, text: str):
        self.text = text.replace('\r\n', '\n')
        self.lines = self.text.split('\n')
        self.line_starts = [0] + [m.end() for m in re.finditer('\n', self.text)]
        self.tokens = tokenize(self.text)
        self.pairs: dict[int, int] = {}
        stack: list[int] = []
        for index, token in enumerate(self.tokens):
            if token.kind != 'op':
                continue
            if token.value in ('(', '[', '{'):
                stack.append(index)
            elif token.value in (')', ']', '}') and stack:
                opening = stack.pop()
                self.pairs[opening], self.pairs[index] = index, opening

    def line_at(self, offset: int) -> int:
        return bisect.bisect_right(self.line_starts, offset)

    def tok(self, index: int) -> Token:
        return self.tokens[index] if 0 <= index < len(self.tokens) else EOF

    def is_op(self, index: int, *values: str) -> bool:
        token = self.tok(index)
        return token.kind == 'op' and token.value in values

    def is_name(self, index: int, *values: str) -> bool:
        token = self.tok(index)
        return token.kind == 'name' and (not values or token.value in values)

    def is_field(self, index: int) -> bool:
        """True when the name at index follows '.' or ':' (a field or method, not a variable)."""
        return self.is_op(index - 1, '.', ':')

    def is_global_name(self, index: int, value: str) -> bool:
        """The variable `value` itself, or _G.value."""
        if not self.is_name(index, value):
            return False
        return not self.is_field(index) or (self.is_op(index - 1, '.') and self.is_name(index - 2, '_G')
                                            and not self.is_field(index - 2))

    def split(self, lo: int, hi: int) -> list[tuple[int, int]]:
        """Token ranges of the comma-separated expressions in [lo, hi)."""
        parts, start, k = [], lo, lo
        while k < hi:
            token = self.tokens[k]
            if token.kind == 'op' and token.value in ('(', '[', '{') and k in self.pairs:
                k = self.pairs[k] + 1
                continue
            if token.kind == 'op' and token.value == ',':
                parts.append((start, k))
                start = k + 1
            k += 1
        if start < hi:
            parts.append((start, hi))
        return parts

    def chain_end(self, k: int) -> int:
        """Index after a run of [index] and .field suffixes starting at k."""
        while True:
            if self.is_op(k, '[') and k in self.pairs:
                k = self.pairs[k] + 1
            elif self.is_op(k, '.') and self.is_name(k + 1):
                k += 2
            else:
                return k

    def requires(self, k: int, module: str) -> bool:
        """require('module') or require 'module' starting at k."""
        if not self.is_name(k, 'require'):
            return False
        if self.tok(k + 1).kind == 'string':
            return self.tok(k + 1).value == module
        return (self.is_op(k + 1, '(') and self.tok(k + 2).kind == 'string'
                and self.tok(k + 2).value == module and self.is_op(k + 3, ')'))

    def rawget_global(self, k: int, pattern: re.Pattern) -> bool:
        """rawget(_G, '<name matching pattern>') starting at k."""
        return (self.is_name(k, 'rawget') and self.is_op(k + 1, '(') and self.is_name(k + 2, '_G')
                and self.is_op(k + 3, ',') and self.tok(k + 4).kind == 'string'
                and bool(pattern.fullmatch(self.tok(k + 4).value)) and self.is_op(k + 5, ')'))

    def local_targets(self):
        """Yields (names, index after '=') for each `local a, b = ...` statement."""
        for k, token in enumerate(self.tokens):
            if token.kind != 'keyword' or token.value != 'local':
                continue
            names, j = [], k + 1
            while self.is_name(j):
                names.append(self.tokens[j].value)
                j += 1
                if not self.is_op(j, ','):
                    break
                j += 1
            if names and self.is_op(j, '='):
                yield names, j + 1


# ----------------------------------------------------------------------------- strings handed to the FFI

@dataclass
class CText:
    """C declarations or a type string from one or more Lua string literals, with source lines."""
    text: str
    lines: list[int]

    def line_of(self, index: int) -> int:
        return self.lines[min(index, len(self.lines) - 1)] if self.lines else 0


DYNAMIC = ' __lint_dynamic__ '


def ctext(source: Source, tokens: list[Token]) -> CText:
    """Concatenates string tokens (non-string parts become a placeholder name)."""
    text, lines = [], []
    for token in tokens:
        if token.kind != 'string':
            text.append(DYNAMIC)
            lines.extend([token.line] * len(DYNAMIC))
            continue
        text.append(token.value)
        if token.content >= 0:  # long string: the value is the source text
            line = source.line_at(token.content)
            for ch in token.value:
                lines.append(line)
                line += ch == '\n'
        else:
            lines.extend([token.line] * len(token.value))
    return CText(''.join(text), lines)


def string_constants(source: Source) -> dict[str, list[tuple[int, Token]]]:
    """`local NAME = 'literal'` definitions: name -> [(token index, string token)]."""
    found: dict[str, list[tuple[int, Token]]] = {}
    for names, j in source.local_targets():
        if len(names) == 1 and source.tok(j).kind == 'string' and not source.is_op(j + 1, '..', '(', ':', '['):
            found.setdefault(names[0], []).append((j, source.tok(j)))
    return found


def latest(definitions: dict[str, list[tuple[int, Token]]], name: str, before: int) -> Token | None:
    candidates = [token for index, token in definitions.get(name, []) if index < before]
    return candidates[-1] if candidates else None


def loop_strings(source: Source, name_index: int) -> list[Token] | None:
    """String elements of `for _, NAME in ipairs({...})` / `pairs({...})` enclosing name_index."""
    name = source.tok(name_index).value
    for k in range(name_index - 1, -1, -1):
        token = source.tokens[k]
        if token.kind != 'keyword' or token.value != 'for':
            continue
        j, variables = k + 1, []
        while source.is_name(j):
            variables.append(source.tokens[j].value)
            j += 1 + source.is_op(j + 1, ',')
            if not source.is_name(j):
                break
        if name not in variables or not (source.tok(j).kind == 'keyword' and source.tok(j).value == 'in'):
            continue
        if (source.is_name(j + 1, 'ipairs', 'pairs') and source.is_op(j + 2, '(')
                and source.is_op(j + 3, '{') and j + 3 in source.pairs):
            close = source.pairs[j + 3]
            if close < name_index:
                strings = []
                for lo, hi in source.split(j + 4, close):
                    if hi - lo == 1 and source.tokens[lo].kind == 'string':
                        strings.append(source.tokens[lo])
                return strings
        return None
    return None


# ----------------------------------------------------------------------------- C declarations (R1)

C_KEYWORDS = frozenset(('int', 'char', 'short', 'long', 'float', 'double', 'void', 'signed', 'unsigned',
                        'const', 'volatile', 'struct', 'union', 'enum', 'typedef', 'extern', 'static',
                        'inline', '__inline', '__inline__', '__cdecl', '__stdcall', '__fastcall',
                        '__thiscall', '__attribute__', '__declspec', '__asm__', '__asm', 'asm', 'sizeof',
                        '_Bool', 'bool', '__extension__', 'restrict', '__restrict', '__restrict__',
                        '__alignof__', '__alignof', '__typeof__', '__typeof', 'typeof', '__ptr32', '__ptr64'))
C_COMMENT_RE = re.compile(r'/\*.*?\*/|//[^\n]*|^[ \t]*#[^\n]*', re.S | re.M)
ASM_LABEL_RE = re.compile(r'\b(?:__asm__|__asm|asm)\s*\(\s*"([^"]*)"\s*\)')
POINTER_DECLARATOR_RE = re.compile(r'\s*(?:(?:__cdecl|__stdcall|__fastcall|__thiscall)\s*)*\*')


def _blank(text: str, start: int, end: int) -> str:
    return text[:start] + ''.join('\n' if ch == '\n' else ' ' for ch in text[start:end]) + text[end:]


def _blank_groups(text: str, opening: str, closing: str, prefix: re.Pattern | None = None) -> str:
    """Blanks balanced opening...closing groups (all of them, or those right after prefix)."""
    starts = ([m.start() for m in prefix.finditer(text)] if prefix
              else [i for i, ch in enumerate(text) if ch == opening])
    for start in reversed(starts):
        i = text.find(opening, start)
        if i < 0:
            continue
        depth = 0
        for j in range(i, len(text)):
            if text[j] == opening:
                depth += 1
            elif text[j] == closing:
                depth -= 1
                if depth == 0:
                    text = _blank(text, start, j + 1)
                    break
    return text


def _split_top(text: str, separator: str) -> list[tuple[str, int]]:
    parts, depth, start = [], 0, 0
    for i, ch in enumerate(text):
        if ch in '({[':
            depth += 1
        elif ch in ')}]':
            depth -= 1
        elif ch == separator and depth == 0:
            parts.append((text[start:i], start))
            start = i + 1
    if text[start:].strip():
        parts.append((text[start:], start))
    return parts


def _function_name(declarator: str) -> tuple[str, int] | None:
    """(name, offset) when the declarator declares a function: `name(...)`, not `(*name)(...)`."""
    depth = 0
    for i, ch in enumerate(declarator):
        if ch == '(':
            if depth == 0:
                name = re.search(r'([A-Za-z_]\w*)\s*$', declarator[:i])
                if not name or name.group(1) in C_KEYWORDS:
                    return None
                if POINTER_DECLARATOR_RE.match(declarator, i + 1):
                    return None
                return name.group(1), name.start(1)
            depth += 1
        elif ch == ')':
            depth -= 1
    return None


ATTRIBUTE_RE = re.compile(r'\b(?:__attribute__|__declspec)\s*\(')


def c_prototypes(text: str):
    """Yields (name, offset, problem) for each function prototype without a private __asm__ label."""
    clean = C_COMMENT_RE.sub(lambda m: ''.join('\n' if ch == '\n' else ' ' for ch in m.group()), text)
    for declaration, offset in _split_top(clean, ';'):
        if re.match(r'\s*typedef\b', declaration):
            continue  # typedefs (function pointer types included) declare no global symbol
        body = _blank_groups(declaration, '{', '}')
        body = _blank_groups(body, '(', ')', ATTRIBUTE_RE)
        for declarator, part_offset in _split_top(body, ','):
            label = ASM_LABEL_RE.search(declarator)
            if label:
                declarator = _blank(declarator, label.start(), label.end())
            found = _function_name(declarator)
            if not found:
                continue
            name, name_offset = found
            if not label:
                yield name, offset + part_offset + name_offset, f'{name}: global prototype without an __asm__ label'
            elif label.group(1) == name:
                yield name, offset + part_offset + name_offset, f'{name}: __asm__ label repeats the global name'


# ----------------------------------------------------------------------------- FFI calls

FFI_FUNCS = frozenset(('cdef', 'cast', 'typeof', 'new', 'metatype', 'sizeof', 'alignof', 'istype', 'offsetof'))
TYPE_FUNCS = FFI_FUNCS - {'cdef'}
FUNCTION_POINTER_RE = re.compile(r'\(\s*(?:(?:__cdecl|__stdcall|__fastcall|__thiscall)\s*)*\*[^()]*\)\s*\(')
ANONYMOUS_RE = re.compile(r'\b(struct|union|enum)\s*\{')


@dataclass
class Call:
    func: str                              # cdef, cast, typeof, ...
    ref: int                               # first token of the reference (ffi, or a local alias)
    args: list[tuple[int, int]] | None     # argument token ranges; None when not called
    close: int                             # last token of the call
    direct: bool                           # called directly, not through pcall/xpcall


def ffi_names(source: Source) -> tuple[set[str], dict[str, str]]:
    """Names of the ffi module (`ffi` and `local x = require('ffi')`) and `local f = ffi.<func>` aliases."""
    modules: set[str] = {'ffi'}
    aliases: dict[str, str] = {}
    for names, j in source.local_targets():
        if len(names) != 1:
            continue
        if source.requires(j, 'ffi'):
            modules.add(names[0])
        elif (source.is_name(j, *modules) and source.is_op(j + 1, '.') and source.is_name(j + 2)
              and source.tok(j + 2).value in FFI_FUNCS
              and not source.is_op(j + 3, '(', '{', '.', ':', '[') and source.tok(j + 3).kind != 'string'):
            aliases[names[0]] = source.tok(j + 2).value
    return modules, aliases


def ffi_calls(source: Source) -> list[Call]:
    """Every reference to ffi.<func> (or an alias of it) with its call arguments."""
    modules, aliases = ffi_names(source)
    calls = []
    for k, token in enumerate(source.tokens):
        if token.kind != 'name' or source.is_field(k):
            continue
        if (token.value in modules and source.is_op(k + 1, '.') and source.is_name(k + 2)
                and source.tok(k + 2).value in FFI_FUNCS):
            func, name_index = source.tok(k + 2).value, k + 2
        elif token.value in aliases and not (source.tok(k - 1).kind == 'keyword' and source.tok(k - 1).value == 'local'):
            func, name_index = aliases[token.value], k
        else:
            continue
        calls.append(_call(source, func, k, name_index))
    return calls


def _call(source: Source, func: str, ref: int, name_index: int) -> Call:
    after = name_index + 1
    token = source.tok(after)
    if source.is_op(after, '(') and after in source.pairs:
        close = source.pairs[after]
        return Call(func, ref, source.split(after + 1, close), close, True)
    if token.kind == 'string':
        return Call(func, ref, [(after, after + 1)], after, True)
    if source.is_op(after, '{') and after in source.pairs:
        return Call(func, ref, [(after, source.pairs[after] + 1)], source.pairs[after], True)
    opening = ref - 1  # pcall(ffi.cdef, ...) / xpcall(ffi.cdef, handler, ...)
    if (source.is_op(opening, '(') and opening in source.pairs and source.is_op(after, ',')
            and source.is_name(opening - 1, 'pcall', 'xpcall') and not source.is_field(opening - 1)):
        close = source.pairs[opening]
        args = source.split(after + 1, close)
        if source.tok(opening - 1).value == 'xpcall':
            args = args[1:]
        return Call(func, ref, args, close, False)
    return Call(func, ref, None, name_index, False)


# ----------------------------------------------------------------------------- rules

Finding = tuple[str, int, str]  # rule, line, detail
LOADER_RE = re.compile(r'.*loader.*', re.I)
COMPARISONS = ('<', '<=', '>', '>=', '==', '~=')


def rule_cdef(source: Source, calls: list[Call]) -> list[Finding]:
    """R1: function prototypes declared in ffi.cdef under global names."""
    found = []
    constants = string_constants(source)
    for call in calls:
        if call.func != 'cdef' or not call.args:
            continue
        lo, hi = call.args[0]
        parts = source.tokens[lo:hi]
        texts: list[CText] | None = None
        if any(t.kind == 'string' for t in parts):
            texts = [ctext(source, [t for t in parts if t.kind == 'string' or t.kind == 'name'])]
        elif hi - lo == 1 and parts[0].kind == 'name':
            strings = loop_strings(source, lo)
            if strings is None:
                constant = latest(constants, parts[0].value, lo)
                strings = [constant] if constant else None
            if strings is not None:
                texts = [ctext(source, [s]) for s in strings]
        if texts is None:
            found.append(('R1', source.tok(lo).line, 'cdef argument is not a string literal: labels cannot be checked'))
            continue
        for declarations in texts:
            for _name, offset, problem in c_prototypes(declarations.text):
                found.append(('R1', declarations.line_of(offset), problem))
    return found


def rule_type_string(source: Source, calls: list[Call]) -> list[Finding]:
    """R2: ffi type strings that create a new C type each time they are evaluated."""
    found = []
    constants = string_constants(source)
    for call in calls:
        if call.func not in TYPE_FUNCS or not call.args:
            continue
        lo, hi = call.args[0]
        strings = [t for t in source.tokens[lo:hi] if t.kind == 'string']
        if not strings and hi - lo == 1 and source.tok(lo).kind == 'name':
            constant = latest(constants, source.tok(lo).value, lo)
            strings = [constant] if constant else []
        for string in strings:
            kind = type_string_problem(string.value)
            if kind:
                found.append(('R2', source.tok(lo).line,
                              f"ffi.{call.func}('{normalise(string.value)}'): {kind} string makes a new C type per evaluation"))
                break
    return found


def type_string_problem(text: str) -> str | None:
    if FUNCTION_POINTER_RE.search(text):
        return 'function-pointer type'
    anonymous = ANONYMOUS_RE.search(text)
    return f'anonymous {anonymous.group(1)}' if anonymous else None


def rule_raw_store(source: Source, calls: list[Call]) -> list[Finding]:
    """R3: stores through ffi.cast(...)[i] / .field, or through a pointer cast from a constant address."""
    found = []
    for call in calls:
        if call.func == 'cast' and call.direct and call.args is not None:
            end = source.chain_end(call.close + 1)
            if end > call.close + 1 and source.is_op(end, '='):
                found.append(('R3', source.tok(call.ref).line, 'store through an ffi.cast pointer'))
    modules, _aliases = ffi_names(source)
    bases: dict[str, str] = {}
    for names, j in source.local_targets():
        for name in names:
            if not (source.is_name(j, *modules) and source.is_op(j + 1, '.') and source.is_name(j + 2, 'cast')
                    and source.is_op(j + 3, '(') and source.tok(j + 4).kind == 'string'
                    and source.is_op(j + 5, ',') and source.tok(j + 6).kind == 'number' and source.is_op(j + 7, ')')):
                break
            bases[name] = source.tok(j + 4).value
            j += 8
            if not source.is_op(j, ','):
                break
            j += 1
    for k, token in enumerate(source.tokens):
        if token.kind == 'name' and token.value in bases and not source.is_field(k):
            end = source.chain_end(k + 1)
            if end > k + 1 and source.is_op(end, '='):
                found.append(('R3', token.line,
                              f"store through {token.value} = ffi.cast('{bases[token.value]}', constant address)"))
    return found


def rule_gc(source: Source) -> list[Finding]:
    """R4: collectgarbage with any option other than 'count'."""
    found = []
    for k, token in enumerate(source.tokens):
        if not source.is_global_name(k, 'collectgarbage'):
            continue
        option: Token | None = None
        if source.is_op(k + 1, '(') and k + 1 in source.pairs:
            close = source.pairs[k + 1]
            args = source.split(k + 2, close)
            if not args:
                found.append(('R4', token.line, "collectgarbage() runs a full collection"))
                continue
            lo, hi = args[0]
            option = source.tok(lo) if hi - lo == 1 else Token('expr', '', token.line)
        elif source.tok(k + 1).kind == 'string':
            option = source.tok(k + 1)
        elif source.is_op(k + 1, ',') and source.is_op(k - 1, '('):  # pcall(collectgarbage, 'collect')
            option = source.tok(k + 2)
        if option is None or (option.kind == 'string' and option.value == 'count'):
            continue
        shown = f"'{option.value}'" if option.kind == 'string' else 'a non-literal option'
        found.append(('R4', token.line, f'collectgarbage({shown}) changes the GC for the game and every mod'))
    return found


def _aliases(source: Source, module: str, pattern: re.Pattern) -> set[str]:
    """Locals bound to require('module'), rawget(_G, 'module') or the global itself."""
    names = set()
    for targets, j in source.local_targets():
        if len(targets) != 1:
            continue
        ends_statement = source.tok(j + 1).line != source.tok(j).line or source.is_op(j + 1, ';')
        if (source.requires(j, module) or source.rawget_global(j, pattern)
                or (source.is_name(j, module) and ends_statement)
                or (source.is_name(j, '_G') and source.is_op(j + 1, '.') and source.is_name(j + 2, module))):
            names.add(targets[0])
    return names


def rule_jit(source: Source) -> list[Finding]:
    """R5: jit.flush, jit.opt, jit.attach and argument-less jit.on()/jit.off()."""
    found = []
    names = {'jit'} | _aliases(source, 'jit', re.compile('jit'))
    for k, token in enumerate(source.tokens):
        if token.kind != 'name':
            continue
        if token.value in names and not source.is_field(k) and source.is_op(k + 1, '.') and source.is_name(k + 2):
            member = source.tok(k + 2).value
            if member == 'flush':
                found.append(('R5', token.line, 'jit.flush discards compiled code of the game and every mod'))
            elif member == 'opt':
                found.append(('R5', token.line, 'jit.opt changes JIT settings for the game and every mod'))
            elif member == 'attach':
                found.append(('R5', token.line, 'jit.attach replaces the one handler per event the state keeps'))
            elif member in ('on', 'off') and source.is_op(k + 3, '(') and source.is_op(k + 4, ')'):
                found.append(('R5', token.line, f'jit.{member}() without a function switches the JIT for every mod'))
        elif token.value == 'opt' and source.is_op(k + 1, '.') and source.is_name(k + 2, 'start'):
            found.append(('R5', token.line, 'opt.start changes JIT limits for the game and every mod'))
        elif source.requires(k, 'jit.opt'):
            found.append(('R5', token.line, "require('jit.opt') changes JIT settings for every mod"))
    return found


def rule_os_clock(source: Source) -> list[Finding]:
    """R6: os.clock aborts trace compilation and is coarse."""
    return [('R6', token.line, 'os.clock aborts traces; time with QueryPerformanceCounter')
            for k, token in enumerate(source.tokens)
            if source.is_global_name(k, 'os') and source.is_op(k + 1, '.') and source.is_name(k + 2, 'clock')]


def rule_loader_version(source: Source) -> list[Finding]:
    """R7: numeric comparisons of the loader's version field."""
    found = []
    loaders = _aliases(source, 'CowboyBingusModLoader', re.compile(r'\w*Loader'))
    for k, token in enumerate(source.tokens):
        if not (token.kind == 'name' and token.value == 'version' and source.is_op(k - 1, '.')):
            continue
        receiver = source.tok(k - 2)
        start = k - 2
        if receiver.kind == 'name' and (LOADER_RE.fullmatch(receiver.value) or receiver.value in loaders):
            while source.is_op(start - 1, '.') and source.is_name(start - 2):
                start -= 2
        elif source.is_op(k - 2, ')') and k - 2 in source.pairs:
            opening = source.pairs[k - 2]
            if not (source.is_name(opening - 1, 'rawget') and any(
                    t.kind == 'string' and LOADER_RE.fullmatch(t.value) for t in source.tokens[opening:k - 2])):
                continue
            start = opening - 1
        else:
            continue
        if source.is_op(start - 1, '(') and source.is_name(start - 2, 'type') and source.is_op(k + 1, ')'):
            continue  # type(loader.version) == 'number' is a type check, not a version comparison
        after = k + 1
        while True:  # skip `or 0` defaults and closing parentheses: (loader.version or 0) >= 17
            if source.tok(after).kind == 'keyword' and source.tok(after).value == 'or' and source.tok(after + 1).kind in ('number', 'string'):
                after += 2
            elif source.is_op(after, ')'):
                after += 1
            else:
                break
        before = start - 1
        while source.is_op(before, '(') or source.is_name(before, 'tonumber'):
            before -= 1
        if source.is_op(after, *COMPARISONS) or source.is_op(before, *COMPARISONS):
            found.append(('R7', token.line, 'loader version comparison: check capabilities (loader.api, loader.jit, functions) instead'))
    return found


def rule_explicit_globals(source: Source) -> list[tuple[int, str]]:
    """R8 part 2: rawset(_G, 'name', v), _G.name = v and _G['name'] = v (these compile to no GSET)."""
    writes = []
    for k, token in enumerate(source.tokens):
        if source.is_name(k, 'rawset') and not source.is_field(k) and source.is_op(k + 1, '(') and source.is_name(k + 2, '_G') and source.is_op(k + 3, ','):
            name = source.tok(k + 4)
            writes.append((token.line, name.value if name.kind == 'string' else '?'))
        elif source.is_name(k, '_G') and not source.is_field(k):
            if source.is_op(k + 1, '.') and source.is_name(k + 2) and source.is_op(k + 3, '='):
                writes.append((token.line, source.tok(k + 2).value))
            elif (source.is_op(k + 1, '[') and source.tok(k + 2).kind == 'string'
                  and source.is_op(k + 3, ']') and source.is_op(k + 4, '=')):
                writes.append((token.line, source.tok(k + 2).value))
    return writes


def rule_catch_previous(source: Source) -> list[Finding]:
    """R9: pcall/xpcall around the previous or original update, and error((...), 0) rethrows."""
    found = []
    for k, token in enumerate(source.tokens):
        if (source.is_name(k, 'pcall', 'xpcall') and not source.is_field(k) and source.is_op(k + 1, '(')
                and source.is_name(k + 2) and re.match(r'(previous|original)', source.tok(k + 2).value)):
            found.append(('R9', token.line, f'{token.value}({source.tok(k + 2).value}, ...) catches errors of another layer'))
        elif (source.is_name(k, 'error') and not source.is_field(k) and source.is_op(k + 1, '(') and source.is_op(k + 2, '(')
              and source.is_op(k + 3, '...') and source.is_op(k + 4, ')') and source.is_op(k + 5, ',')
              and source.tok(k + 6).kind == 'number' and source.tok(k + 6).value == '0' and source.is_op(k + 7, ')')):
            found.append(('R9', token.line, 'error((...), 0) rethrows a caught error from this frame'))
    return found


# ----------------------------------------------------------------------------- R8: GSET from the LuaJIT bytecode

GSET_LISTER = r"""
-- Reads file paths from stdin, compiles each (no execution) and prints one line per GSET:
-- path TAB line TAB name TAB instruction (as jit.bc, the -bl lister, prints it); and one line
-- per function: F TAB path TAB first line TAB last line TAB params TAB upvalues TAB stack slots.
local bc, util, vmdef = require('jit.bc'), require('jit.util'), require('jit.vmdef')
local funcbc, funck, funcinfo = util.funcbc, util.funck, util.funcinfo
local function walk(fn, path)
  local info = funcinfo(fn)
  io.write('F\t', path, '\t', info.linedefined, '\t', info.lastlinedefined, '\t', info.params, '\t',
           info.upvalues, '\t', info.stackslots, '\n')
  for n = -1, -1000000000, -1 do
    local k = funck(fn, n)
    if k == nil then break end
    if type(k) == 'proto' then walk(k, path) end
  end
  for pc = 1, 1000000000 do
    local ins = funcbc(fn, pc)
    if not ins then break end
    local op = ins % 256
    if vmdef.bcnames:sub(6 * op + 1, 6 * op + 6) == 'GSET  ' then
      local name = funck(fn, -(math.floor(ins / 65536) % 65536) - 1)
      local text = bc.line(fn, pc):gsub('%s+$', '')
      io.write(path, '\t', funcinfo(fn, pc).currentline, '\t', name, '\t', text, '\n')
    end
  end
end
for path in io.read('*a'):gmatch('[^\r\n]+') do
  local fn, err = loadfile(path)
  if fn then walk(fn, path) else io.write('!\t', path, '\t', (tostring(err):gsub('[\r\n\t]', ' ')), '\n') end
end
"""


@dataclass(frozen=True)
class Compiled:
    """LuaJIT's own numbers for one function (line 0 is the main chunk)."""
    line: int
    last: int
    params: int
    upvalues: int
    slots: int


def global_writes(luajit: Path, files: list[Path]) -> dict[str, list[tuple[int, str]]]:
    """Compiles files with the workspace LuaJIT and returns {path: [(line, global name)]} for GSETs."""
    return bytecode_facts(luajit, files)[0]


def bytecode_facts(luajit: Path, files: list[Path]) -> tuple[dict[str, list[tuple[int, str]]],
                                                             dict[str, list[Compiled]]]:
    """Compiles files once with the workspace LuaJIT: ({path: [(line, global)]} for GSETs,
    {path: [Compiled per function]})."""
    result: dict[str, list[tuple[int, str]]] = {str(path): [] for path in files}
    compiled: dict[str, list[Compiled]] = {str(path): [] for path in files}
    if not files:
        return result, compiled
    if not luajit.is_file():
        raise LintError(f'LuaJIT not found: {luajit} (needed for R8; set "luajit" in the config or --luajit)')
    env = dict(os.environ, LUA_PATH=str(luajit.parent / '?.lua') + ';;')
    with tempfile.TemporaryDirectory() as folder:
        script = Path(folder) / 'gset_lister.lua'
        script.write_text(GSET_LISTER, encoding='utf-8')
        done = subprocess.run([str(luajit), str(script)], input='\n'.join(str(p) for p in files),
                              capture_output=True, text=True, encoding='utf-8', errors='replace', env=env)
    if done.returncode != 0:
        raise LintError(f'LuaJIT bytecode listing failed ({done.returncode}): {done.stderr.strip()}')
    errors = []
    for row in done.stdout.splitlines():
        parts = row.split('\t')
        if parts[0] == '!':
            errors.append(f'{parts[1]}: {parts[2] if len(parts) > 2 else "compile error"}')
        elif parts[0] == 'F' and len(parts) == 7 and parts[1] in compiled:
            compiled[parts[1]].append(Compiled(*map(int, parts[2:])))
        elif len(parts) >= 3 and parts[0] in result:
            result[parts[0]].append((int(parts[1]), parts[2]))
    if errors:
        raise LintError('cannot compile:\n  ' + '\n  '.join(errors))
    return result, compiled


# ----------------------------------------------------------------------------- scanning

SUPPRESS_RE = re.compile(r'--\s*lint-ok:\s*((?:R\d+\s*[, ]\s*)*R\d+)\s+\S')


@dataclass
class Repo:
    name: str
    path: Path
    sources: list[str]
    tests: list[str]
    allowed: frozenset[str]


@dataclass
class Violation:
    repo: str
    rule: str
    file: str
    line: int
    text: str
    detail: str
    kind: str  # source or test
    weight: int = 1  # R10-R15: the measured value, so the ratchet also catches a function getting worse

    def key(self) -> tuple[str, str, str, str, str]:
        return (self.repo, self.kind, self.file, self.rule, normalise(self.text))

    def as_json(self) -> dict:
        return {'repo': self.repo, 'rule': self.rule, 'name': RULES[self.rule], 'file': self.file,
                'line': self.line, 'text': self.text, 'detail': self.detail, 'kind': self.kind,
                'value': self.weight}


@dataclass
class Scan:
    repos: list[Repo]
    include_tests: bool
    violations: list[Violation] = field(default_factory=list)
    suppressed: list[Violation] = field(default_factory=list)
    files: int = 0


def normalise(text: str) -> str:
    return ' '.join(text.split())


def suppressed_rules(line: str) -> set[str]:
    match = SUPPRESS_RE.search(line)
    return set(re.findall(r'R\d+', match.group(1))) if match else set()


def structure_findings(source: Source, compiled: list[Compiled] | None, limits: dict) -> list[tuple]:
    """R10-R13 and R15 for one source file: (rule, line, detail, measured value)."""
    main, functions = metrics.analyse(source.tokens)
    found: list[tuple] = []
    for function in functions:
        where = f'{function.name}: '
        if function.cognitive > limits['cognitive']:
            found.append(('R10', function.line, f"{where}cognitive complexity {function.cognitive} (limit "
                          f"{limits['cognitive']}), nesting depth {function.nesting}", function.cognitive))
        size = len(function.lines)
        if size > limits['function_lines']:
            found.append(('R11', function.line, f"{where}{size} code lines (limit {limits['function_lines']})", size))
        if function.parameters > limits['parameters']:
            found.append(('R12', function.line, f"{where}{function.parameters} parameters (limit "
                          f"{limits['parameters']})", function.parameters))
    for function in [main] + functions:
        if function.active_locals > limits['active_locals']:
            found.append(('R13', function.active_line, f"{function.name}: {function.active_locals} locals in "
                          f"scope at once (LuaJIT limit 200, warning above {limits['active_locals']})",
                          function.active_locals))
    for fact in compiled or []:
        line = max(fact.line, 1)
        if fact.upvalues > limits['upvalues']:
            found.append(('R13', line, f"{fact.upvalues} upvalues (LuaJIT limit 60, warning above "
                          f"{limits['upvalues']})", fact.upvalues))
        if fact.slots > limits['stack_slots']:
            found.append(('R13', line, f"{fact.slots} stack slots (LuaJIT limit 250, warning above "
                          f"{limits['stack_slots']})", fact.slots))
    module_lines = len({token.line for token in source.tokens if token.kind != 'eof'})
    if module_lines > limits['module_lines']:
        found.append(('R15', 1, f"{module_lines} code lines in one file (limit {limits['module_lines']})",
                      module_lines))
    return found


def scan_text(repo: Repo, rel: str, text: str, kind: str, gsets: list[tuple[int, str]] | None,
              compiled: list[Compiled] | None = None, limits: dict | None = None,
              source: Source | None = None) -> tuple[list[Violation], list[Violation]]:
    """Runs every rule on one file; returns (violations, suppressed), one per rule and line."""
    try:
        source = source or Source(text)
    except LintError as problem:
        raise LintError(f'{repo.name}/{rel}: {problem}') from None
    calls = ffi_calls(source)
    findings: list[Finding] = []
    findings += rule_cdef(source, calls)
    findings += rule_type_string(source, calls)
    findings += rule_raw_store(source, calls)
    findings += rule_gc(source)
    findings += rule_jit(source)
    findings += rule_os_clock(source)
    findings += rule_loader_version(source)
    if kind == 'source':
        allowed = set(DEFAULT_ALLOWED_GLOBALS) | repo.allowed
        writes = list(gsets or []) + rule_explicit_globals(source)
        findings += [('R8', line, f"global '{name}' written into the shared Lua state")
                     for line, name in writes if name not in allowed]
        findings += rule_catch_previous(source)
        findings += structure_findings(source, compiled, limits or metrics.LIMITS)
    else:
        findings = [f for f in findings if f[0] in TEST_RULES]
    return _violations(repo, rel, kind, source.lines, findings)


def _violations(repo: Repo, rel: str, kind: str, lines: list[str], findings: list[tuple]) -> tuple[list[Violation], list[Violation]]:
    """One violation per rule and line (details joined, values added); suppressed by lint-ok."""
    merged: dict[tuple[str, int], tuple[list[str], int]] = {}
    for finding in findings:
        rule, line, detail = finding[:3]
        weight = finding[3] if len(finding) > 3 else 1
        details, total = merged.get((rule, line), ([], 0))
        if detail not in details:
            details.append(detail)
        merged[(rule, line)] = (details, total + weight if rule in STRUCTURE_RULES else 1)
    kept, dropped = [], []
    for (rule, line), (details, weight) in sorted(merged.items(), key=lambda item: (item[0][1], item[0][0])):
        line_text = lines[line - 1] if 0 < line <= len(lines) else ''
        violation = Violation(repo.name, rule, rel, line, line_text.strip(), '; '.join(details), kind, weight)
        (dropped if rule in suppressed_rules(line_text) else kept).append(violation)
    return kept, dropped


def repo_files(repo: Repo, include_tests: bool) -> tuple[list[Path], list[Path]]:
    if not repo.path.is_dir():
        raise LintError(f'{repo.name}: repository folder not found: {repo.path}')
    tests: set[Path] = set()
    for pattern in repo.tests:
        tests.update(p for p in repo.path.glob(pattern) if p.is_file())
    sources: set[Path] = set()
    for pattern in repo.sources:
        sources.update(p for p in repo.path.glob(pattern) if p.is_file())
    sources -= tests
    return sorted(sources), (sorted(tests) if include_tests else [])


def scan(repos: list[Repo], luajit: Path, include_tests: bool, limits: dict | None = None,
         vendored: tuple[str, ...] = DEFAULT_VENDORED, corpus: list[Repo] | None = None) -> Scan:
    """Scans repos. R14 compares their sources with every repo in corpus (default: repos), so a
    repo's duplicated code does not depend on which repos --only selected."""
    limits = dict(metrics.LIMITS, **(limits or {}))
    result = Scan(repos, include_tests)
    plan = []
    for repo in repos:
        sources, tests = repo_files(repo, include_tests)
        plan += [(repo, path, 'source') for path in sources] + [(repo, path, 'test') for path in tests]
    gsets, compiled = bytecode_facts(luajit, [path for _, path, kind in plan if kind == 'source'])
    parsed = []
    for repo, path, kind in plan:
        text = path.read_text(encoding='utf-8-sig', errors='replace')
        rel = path.relative_to(repo.path).as_posix()
        try:
            source = Source(text)
        except LintError as problem:
            raise LintError(f'{repo.name}/{rel}: {problem}') from None
        is_source = kind == 'source'
        kept, dropped = scan_text(repo, rel, text, kind, gsets.get(str(path)) if is_source else None,
                                  compiled.get(str(path)) if is_source else None, limits, source)
        result.violations += kept
        result.suppressed += dropped
        result.files += 1
        if is_source and path.name not in vendored:
            parsed.append((repo, rel, source))
    selected = {repo.name for repo in repos}
    for repo in corpus or []:
        if repo.name in selected:
            continue
        for path in repo_files(repo, False)[0]:
            if path.name not in vendored:
                text = path.read_text(encoding='utf-8-sig', errors='replace')
                parsed.append((repo, path.relative_to(repo.path).as_posix(), Source(text)))
    kept, dropped = duplicated_code(parsed, limits['clone_tokens'], selected)
    result.violations += kept
    result.suppressed += dropped
    return result


def duplicated_code(parsed: list[tuple[Repo, str, Source]], length: int,
                    report: set[str]) -> tuple[list[Violation], list[Violation]]:
    """R14: regions of at least `length` tokens that occur again in any parsed source; reported
    for the repos named in report."""
    files = [[t for t in source.tokens if t.kind != 'eof'] for _, _, source in parsed]
    findings: dict[int, list[tuple]] = {}
    for clone in metrics.duplicates(files, length):
        repo, rel, source = parsed[clone.file]
        if repo.name not in report:
            continue
        other_repo, other_rel, _ = parsed[clone.other_file]
        other_line = files[clone.other_file][clone.other_start].line
        where = other_rel if (other_repo.name, other_rel) == (repo.name, rel) else f'{other_repo.name} {other_rel}'
        tokens = clone.end - clone.start
        findings.setdefault(clone.file, []).append((
            'R14', files[clone.file][clone.start].line,
            f'{tokens} tokens also at {where}:{other_line}; share one copy (a module or bingus_runtime.lua)',
            tokens))
    kept, dropped = [], []
    for index, found in findings.items():
        repo, rel, source = parsed[index]
        k, d = _violations(repo, rel, 'source', source.lines, found)
        kept += k
        dropped += d
    return kept, dropped


# ----------------------------------------------------------------------------- configuration

def load_settings(path: Path) -> tuple[dict, tuple[str, ...]]:
    """Structure limits (metrics.LIMITS overridden by the config's "limits") and vendored file names."""
    try:
        config = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError) as problem:
        raise LintError(f'cannot read config {path}: {problem}') from None
    unknown = set(config.get('limits', {})) - set(metrics.LIMITS)
    if unknown:
        raise LintError(f'unknown limits in {path.name}: {", ".join(sorted(unknown))}')
    return dict(metrics.LIMITS, **config.get('limits', {})), tuple(config.get('vendored', DEFAULT_VENDORED))


def load_config(path: Path, overrides: list[str], only: list[str], luajit: Path | None,
                corpus: list[Repo] | None = None) -> tuple[list[Repo], Path]:
    """Selected repos and LuaJIT; when corpus is a list, it receives every configured repo."""
    try:
        config = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError) as problem:
        raise LintError(f'cannot read config {path}: {problem}') from None
    base = path.parent
    default_sources = config.get('default_sources', list(DEFAULT_SOURCES))
    default_tests = config.get('default_tests', list(DEFAULT_TESTS))
    repos: dict[str, Repo] = {}
    for entry in config.get('repos', []):
        repos[entry['name']] = Repo(entry['name'], (base / entry['path']).resolve(),
                                    list(entry.get('sources', default_sources)),
                                    list(entry.get('tests', default_tests)),
                                    frozenset(entry.get('allowed_globals', [])))
    for override in overrides:
        name, sep, folder = override.partition('=')
        if not sep or not name or not folder:
            raise LintError(f'--repo expects NAME=PATH, got {override!r}')
        if name in repos:
            repos[name].path = Path(folder).resolve()
        else:
            print(f'note: {name} is not in {path.name}; scanning it with the default globs and globals', file=sys.stderr)
            repos[name] = Repo(name, Path(folder).resolve(), list(default_sources), list(default_tests), frozenset())
    selected = list(repos.values())
    if corpus is not None:
        corpus.extend(selected)
    if only:
        wanted = {name for item in only for name in item.split(',') if name}
        unknown = wanted - set(repos)
        if unknown:
            raise LintError(f'--only names unknown repos: {", ".join(sorted(unknown))}')
        selected = [repo for repo in selected if repo.name in wanted]
    exe = luajit or (base / config.get('luajit', '')).resolve()
    return selected, exe


# ----------------------------------------------------------------------------- baseline

Key = tuple[str, str, str, str, str]  # repo, kind, file, rule, normalised line text


def counts(violations: list[Violation]) -> dict[Key, int]:
    """Per identity: the number of violations (R1-R9) or the measured values added up (R10-R15)."""
    result: dict[Key, int] = {}
    for violation in violations:
        result[violation.key()] = result.get(violation.key(), 0) + violation.weight
    return result


def read_baseline(path: Path) -> dict[Key, int]:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
        return {(e['repo'], e['kind'], e['file'], e['rule'], e['text']): int(e['count']) for e in data['entries']}
    except (OSError, ValueError, KeyError, TypeError) as problem:
        raise LintError(f'cannot read baseline {path}: {problem}') from None


def write_baseline(path: Path, entries: dict[Key, int]) -> None:
    rows = [json.dumps({'repo': k[0], 'kind': k[1], 'file': k[2], 'rule': k[3], 'text': k[4], 'count': n},
                       ensure_ascii=False)
            for k, n in sorted(entries.items()) if n > 0]
    body = ('{\n  "format": 1,\n'
            '  "note": "Known lint violations per (repo, kind, file, rule, normalised line text). '
            '`python lint.py check` fails when a count rises; `python lint.py update` rewrites this file.",\n'
            '  "entries": [\n    ' + ',\n    '.join(rows) + '\n  ]\n}\n')
    path.write_text(body, encoding='utf-8', newline='\n')


def in_scope(key: Key, result: Scan) -> bool:
    return key[0] in {repo.name for repo in result.repos} and (key[1] == 'source' or result.include_tests)


def compare(baseline: dict[Key, int], current: dict[Key, int], result: Scan):
    increases, decreases = [], []
    for key in sorted(set(baseline) | set(current)):
        if not in_scope(key, result):
            continue
        old, new = baseline.get(key, 0), current.get(key, 0)
        if new > old:
            increases.append((key, old, new))
        elif new < old:
            decreases.append((key, old, new))
    return increases, decreases


# ----------------------------------------------------------------------------- output

def summary_table(result: Scan) -> str:
    rules = list(RULES)
    table = {repo.name: {rule: 0 for rule in rules} for repo in result.repos}
    for violation in result.violations:
        table[violation.repo][violation.rule] += 1
    width = max([len('repo')] + [len(name) for name in table]) + 2
    lines = ['repo'.ljust(width) + ''.join(r.rjust(5) for r in rules) + 'total'.rjust(7)]
    totals = {rule: 0 for rule in rules}
    for name, row in table.items():
        lines.append(name.ljust(width) + ''.join(str(row[r]).rjust(5) for r in rules) + str(sum(row.values())).rjust(7))
        for rule in rules:
            totals[rule] += row[rule]
    lines.append('total'.ljust(width) + ''.join(str(totals[r]).rjust(5) for r in rules) + str(sum(totals.values())).rjust(7))
    return '\n'.join(lines)


def describe(violation: Violation) -> str:
    return (f'{violation.rule} {RULES[violation.rule]}  {violation.repo} {violation.file}:{violation.line}\n'
            f'    {violation.text}\n    -> {violation.detail}')


def print_identities(title: str, changes, result: Scan) -> None:
    by_key: dict[Key, list[Violation]] = {}
    for violation in result.violations:
        by_key.setdefault(violation.key(), []).append(violation)

    def position(change):  # repo, file, first current line
        key = change[0]
        return key[0], key[2], min((v.line for v in by_key.get(key, [])), default=0), key[3]

    for key, old, new in sorted(changes, key=position):
        repo, kind, file, rule, text = key
        lines = ','.join(str(v.line) for v in by_key.get(key, []))
        where = f'{file}:{lines}' if lines else file
        print(f'{title} {rule} {RULES[rule]}  {repo} {where}  (baseline {old}, now {new})')
        print(f'    {text}')
        for violation in by_key.get(key, [])[:1]:
            print(f'    -> {violation.detail}')


# ----------------------------------------------------------------------------- commands

def command_scan(result: Scan, args) -> int:
    if args.json:
        summary: dict[str, dict[str, int]] = {repo.name: {} for repo in result.repos}
        for violation in result.violations:
            summary[violation.repo][violation.rule] = summary[violation.repo].get(violation.rule, 0) + 1
        print(json.dumps({'rules': RULES, 'include_tests': result.include_tests, 'files': result.files,
                          'summary': summary, 'violations': [v.as_json() for v in result.violations],
                          'suppressed': [v.as_json() for v in result.suppressed]}, indent=2, ensure_ascii=False))
        return 0
    if args.list:
        for violation in result.violations:
            print(describe(violation))
        print()
    print(summary_table(result))
    print(f'\n{len(result.violations)} violation(s) in {result.files} file(s); {len(result.suppressed)} suppressed by lint-ok'
          + ('' if result.include_tests else '; tests not scanned (--tests)'))
    return 0


def command_check(result: Scan, args) -> int:
    baseline = read_baseline(args.baseline)
    current = counts(result.violations)
    increases, decreases = compare(baseline, current, result)
    print_identities('NEW', increases, result)
    print_identities('fixed - run update:', decreases, result)
    known = sum(1 for key, n in current.items() if 0 < n <= baseline.get(key, 0))
    print(f'lint check: {len(increases)} new, {len(decreases)} fixed, {known} known identities in '
          f'{len(result.repos)} repo(s); baseline {args.baseline.name}')
    return 1 if increases else 0


def command_update(result: Scan, args) -> int:
    baseline = read_baseline(args.baseline)
    current = counts(result.violations)
    increases, decreases = compare(baseline, current, result)
    if increases and not args.allow_increase and not args.baseline.exists():
        print(f'lint update refused: no baseline at {args.baseline} yet; the current scan has '
              f'{len(result.violations)} violation(s). Create it with --allow-increase.')
        return 1
    if increases and not args.allow_increase:
        print_identities('INCREASE', increases, result)
        print(f'lint update refused: {len(increases)} identity count(s) would rise; fix them, add a '
              f'`-- lint-ok: R<n> <reason>` comment, or rerun with --allow-increase')
        return 1
    entries = {key: n for key, n in baseline.items() if not in_scope(key, result)}
    entries.update(current)
    write_baseline(args.baseline, entries)
    print(f'baseline updated: {sum(1 for n in entries.values() if n > 0)} identities ({len(result.violations)} '
          f'violation(s) in this scan); {len(decreases)} lower or gone, {len(increases)} higher or new than before')
    return 0


def main(argv: list[str] | None = None) -> int:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(errors='replace')
    parser = argparse.ArgumentParser(prog='lint.py', description=__doc__.split('\n\n')[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('command', nargs='?', default='scan', choices=('scan', 'check', 'update'))
    parser.add_argument('--tests', action='store_true', help='also scan test files (rules R1-R7)')
    parser.add_argument('--repo', action='append', default=[], metavar='NAME=PATH', help='lint this checkout of NAME')
    parser.add_argument('--only', action='append', default=[], metavar='NAME', help='limit to these repos')
    parser.add_argument('--json', action='store_true', help='scan: machine-readable output')
    parser.add_argument('--list', action='store_true', help='scan: print every violation')
    parser.add_argument('--allow-increase', action='store_true', help='update: accept counts that rose')
    parser.add_argument('--config', type=Path, default=DEFAULT_CONFIG)
    parser.add_argument('--baseline', type=Path, default=DEFAULT_BASELINE)
    parser.add_argument('--luajit', type=Path)
    args = parser.parse_args(argv)
    try:
        corpus: list[Repo] = []
        repos, luajit = load_config(args.config, args.repo, args.only, args.luajit, corpus)
        limits, vendored = load_settings(args.config)
        result = scan(repos, luajit, args.tests, limits, vendored, corpus)
        return {'scan': command_scan, 'check': command_check, 'update': command_update}[args.command](result, args)
    except LintError as problem:
        print(f'lint.py: {problem}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
