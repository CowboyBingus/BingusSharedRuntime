"""Runs tests/test_hostile_vm.lua in a LuaJIT executable and in the installed game's lua51.dll.

The game's DLL is loaded in-process by game_lua.py; the game is never started.
Run: python -m unittest discover -s tests -v   (from the repository folder)
"""
import unittest

import support

LUA_TEST = support.TESTS / 'test_hostile_vm.lua'


class HostileVmTests(unittest.TestCase):
    @support.needs_luajit
    def test_luajit(self):
        code, out = support.run_luajit(LUA_TEST, support.HELPER)
        self.assertEqual(code, 0, out)
        self.assertRegex(out, r'hostile_vm: \d+ checks passed \(LuaJIT 2\.1')

    @support.needs_game
    def test_game_lua51(self):
        code, out = support.run_game(LUA_TEST, support.HELPER)
        self.assertEqual(code, 0, out)
        self.assertNotIn('ERROR:', out)
        self.assertRegex(out, r'hostile_vm: \d+ checks passed \(LuaJIT 2\.1\.0-alpha\)')


if __name__ == '__main__':
    unittest.main()
