"""Runs tests/test_hostile_vm.lua in the workspace LuaJIT and in the installed game's lua51.dll.

The game's DLL is loaded in-process by PerformanceBaseline/game_lua.py; the game is never started.
Run: python -m unittest discover -s tests -v   (from the Resilience folder)
"""
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LUA_TEST = ROOT / 'tests' / 'test_hostile_vm.lua'
HELPER = ROOT / 'hostile_vm.lua'
LUAJIT = Path(json.loads((ROOT / 'lint-repos.json').read_text(encoding='utf-8'))['luajit'])
GAME_LUA = ROOT.parent / 'PerformanceBaseline' / 'game_lua.py'
GAME_DLL = Path(os.environ.get('HD2_LUA51_DLL',
                               r'C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\bin\lua51.dll'))


def run(command: list[str]) -> tuple[int, str]:
    done = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=300)
    return done.returncode, done.stdout + done.stderr


class HostileVmTests(unittest.TestCase):
    @unittest.skipUnless(LUAJIT.is_file(), f'workspace LuaJIT not found: {LUAJIT}')
    def test_workspace_luajit(self):
        code, out = run([str(LUAJIT), str(LUA_TEST), str(HELPER)])
        self.assertEqual(code, 0, out)
        self.assertRegex(out, r'hostile_vm: \d+ checks passed \(LuaJIT 2\.1')

    @unittest.skipUnless(GAME_LUA.is_file() and GAME_DLL.is_file(), 'game lua51.dll or game_lua.py not found')
    def test_game_lua51(self):
        code, out = run([sys.executable, '-B', str(GAME_LUA), str(LUA_TEST), str(HELPER)])
        self.assertEqual(code, 0, out)
        self.assertNotIn('ERROR:', out)
        self.assertRegex(out, r'hostile_vm: \d+ checks passed \(LuaJIT 2\.1\.0-alpha\)')


if __name__ == '__main__':
    unittest.main()
