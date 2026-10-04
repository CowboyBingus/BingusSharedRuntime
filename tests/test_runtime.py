"""Tests for the three runtime files: each Lua test in a LuaJIT executable and in the game's lua51.dll,
plus checks on the sources themselves.

Run: python -m unittest discover -s tests -v   (from the repository folder)
"""
import re
import sys
import unittest

import support

# Strings the builds of read-only mods refuse in any source file. The core and the
# read side must contain none of them, so that those mods can vendor both.
FORBIDDEN = ('WriteProcessMemory', 'VirtualProtect', 'VirtualAlloc', 'CreateRemoteThread', 'FlushInstructionCache',
             'LoadLibrary', 'Network.', 'RPC.', "ffi.cast('void (*")
FILES = ('bingus_runtime.lua', 'bingus_memory.lua', 'bingus_write.lua')
CANONICAL = 'github.com/CowboyBingus/BingusSharedRuntime, runtime/'


def windows_names() -> set[str]:
    """Every Windows function a runtime file binds (the __asm__ labels)."""
    names = set()
    for name in FILES:
        names.update(re.findall(r'__asm__\("(\w+)"\)', (support.RUNTIME / name).read_text(encoding='utf-8')))
    return names


class Sources(unittest.TestCase):
    def text(self, name: str) -> str:
        return (support.RUNTIME / name).read_text(encoding='utf-8')

    def test_core_and_read_side_contain_no_forbidden_string(self):
        for name in ('bingus_runtime.lua', 'bingus_memory.lua'):
            text = self.text(name)
            for forbidden in FORBIDDEN:
                with self.subTest(file=name, string=forbidden):
                    self.assertNotIn(forbidden, text)

    def test_the_forbidden_strings_are_found_where_they_are(self):
        # The check above can fail: the write side names its Windows function.
        self.assertIn('WriteProcessMemory', self.text('bingus_write.lua'))

    def test_core_uses_no_ffi_and_names_no_windows_function(self):
        text = self.text('bingus_runtime.lua')
        self.assertIsNone(re.search(r'\bffi\b', text), 'the core uses ffi')
        self.assertIsNone(re.search(r'\brequire\b', text), 'the core mentions require')
        names = windows_names()
        self.assertGreater(len(names), 15)
        for name in sorted(names):
            with self.subTest(name=name):
                self.assertNotIn(name, text)

    def test_write_side_declares_only_its_write_function(self):
        labels = re.findall(r'__asm__\("(\w+)"\)', self.text('bingus_write.lua'))
        self.assertEqual(labels, ['WriteProcessMemory'])

    def test_every_ffi_name_is_private_and_versioned(self):
        for name, prefix in (('bingus_memory.lua', 'bingus_memory1_'), ('bingus_write.lua', 'bingus_write1_')):
            text = self.text(name)
            declared = re.findall(r'(\w+)\s*\([^()]*\)\s*__asm__', text)
            self.assertTrue(declared)
            for function in declared:
                with self.subTest(file=name, function=function):
                    self.assertTrue(function.startswith(prefix), function)
            for type_name in re.findall(r'\b(?:struct|union)\s+(\w+)', text):
                with self.subTest(file=name, type=type_name):
                    self.assertTrue(type_name.startswith(prefix), type_name)

    def test_headers_name_the_canonical_copy_and_version(self):
        for name in FILES:
            text = self.text(name)
            with self.subTest(file=name):
                self.assertTrue(text.startswith(f'-- {name}, version 1: '), text[:60])
                self.assertIn(CANONICAL + name, text)
                self.assertRegex(text, r'\n(?:local \w+ = )\{VERSION = 1\}\n')
                self.assertIn('<bingus_memory.lua>.new(runtime)', text)
                self.assertNotIn('\r', text)


def lua_tests(vm: str, run, exe_sha256):
    """The Lua tests for one VM, as unittest methods."""
    folder, helper = support.RUNTIME, support.HELPER

    def make(script: str, pattern: str, *extra):
        def test(self):
            args = [arg() if callable(arg) else arg for arg in extra]
            code, out = run(support.TESTS / script, folder, helper, *args)
            self.assertEqual(code, 0, out)
            self.assertNotIn('ERROR:', out)
            self.assertRegex(out, pattern + r': \d+ checks passed \(LuaJIT 2\.1')
            if vm == 'game':
                self.assertRegex(out, r'\(LuaJIT 2\.1\.0-alpha\)')
        return test

    return {
        f'test_core_{vm}': make('test_core.lua', 'bingus_runtime'),
        f'test_memory_{vm}': make('test_memory.lua', 'bingus_memory', exe_sha256),
        f'test_write_{vm}': make('test_write.lua', 'bingus_write'),
        f'test_together_{vm}': make('test_together.lua', 'runtime together'),
        f'test_hostile_sdk_{vm}': make('test_hostile_runtime.lua', r'runtime in a hostile VM \(sdk\)', 'sdk', exe_sha256),
        f'test_hostile_clash_{vm}': make('test_hostile_runtime.lua', r'runtime in a hostile VM \(clash\)', 'clash',
                                         exe_sha256),
    }


@support.needs_luajit
class LuaJIT(unittest.TestCase):
    """In a LuaJIT executable: the process's executable is LuaJIT itself."""
    locals().update(lua_tests('luajit', support.run_luajit, lambda: support.sha256(support.LUAJIT)))


@support.needs_game
class GameLua51(unittest.TestCase):
    """In the game's lua51.dll, loaded by game_lua.py inside a Python process."""
    locals().update(lua_tests('game', support.run_game, lambda: support.sha256(sys.executable)))


if __name__ == '__main__':
    unittest.main()
