"""What the test runners share: the repository's paths, the two Lua VMs and how to run a Lua test.

The two VMs:
- a LuaJIT 2.1 executable: BINGUS_LUAJIT, else the "luajit" in lint-repos.json (relative to the
  workspace, see lint.workspace_root);
- the installed game's lua51.dll, loaded in-process by game_lua.py: HD2_LUA51_DLL, else Steam's
  default install folder. The game is never started.
A test for a VM that is not available is skipped.
"""
from __future__ import annotations

import hashlib
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import game_lua  # noqa: E402
import lint  # noqa: E402

TESTS = ROOT / 'tests'
RUNTIME = ROOT / 'runtime'
HELPER = ROOT / 'hostile_vm.lua'
GAME_LUA = ROOT / 'game_lua.py'
LUAJIT = lint.default_luajit()
GAME_DLL = game_lua.game_dll()

needs_luajit = unittest.skipUnless(LUAJIT.is_file(), f'LuaJIT not found: {LUAJIT} (set BINGUS_LUAJIT)')
needs_game = unittest.skipUnless(GAME_DLL.is_file(), f'game lua51.dll not found: {GAME_DLL} (set HD2_LUA51_DLL)')


def sha256(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def run(command: list[str]) -> tuple[int, str]:
    done = subprocess.run([str(part) for part in command], capture_output=True, text=True, encoding='utf-8',
                          errors='replace', timeout=600)
    return done.returncode, done.stdout + done.stderr


def run_luajit(script: Path, *args) -> tuple[int, str]:
    """Runs script in the LuaJIT executable; the process's executable is LuaJIT itself."""
    return run([LUAJIT, script, *args])


def run_game(script: Path, *args) -> tuple[int, str]:
    """Runs script in the game's lua51.dll inside a Python process (its executable: sys.executable)."""
    return run([sys.executable, '-B', GAME_LUA, script, *args])
