"""Runs tests/test_runtime.lua in a LuaJIT executable and in the installed game's lua51.dll.

The game's DLL is loaded in-process by game_lua.py; the game is never started.
Run: python -m unittest discover -s tests -v   (from the repository folder)
"""
import sys
import unittest

import support

LUA_TEST = support.TESTS / 'test_runtime.lua'
RUNTIME = support.RUNTIME / 'bingus_runtime.lua'


class RuntimeTests(unittest.TestCase):
    @support.needs_luajit
    def test_luajit(self):
        code, out = support.run_luajit(LUA_TEST, RUNTIME, support.HELPER, support.sha256(support.LUAJIT))
        self.assertEqual(code, 0, out)
        self.assertRegex(out, r'bingus_runtime: \d+ checks passed \(LuaJIT 2\.1')

    @support.needs_game
    def test_game_lua51(self):
        # game_lua.py runs the test inside a Python process: the executable is sys.executable.
        code, out = support.run_game(LUA_TEST, RUNTIME, support.HELPER, support.sha256(sys.executable))
        self.assertEqual(code, 0, out)
        self.assertNotIn('ERROR:', out)
        self.assertRegex(out, r'bingus_runtime: \d+ checks passed \(LuaJIT 2\.1\.0-alpha\)')


if __name__ == '__main__':
    unittest.main()
