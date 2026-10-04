"""Tests for lint.py: every rule on fixture files, the lint-ok comment and the baseline ratchet.

Fixture lines carry `expect: R<n>` markers; a scan must report exactly the marked lines.
Run: python -m unittest discover -s tests -v   (from the repository folder)
"""
import contextlib
import io
import json
import re
import shutil
import tempfile
import unittest
from pathlib import Path

import support
import lint  # noqa: E402  (support puts the repository on sys.path)

ROOT = support.ROOT
FIXTURE = ROOT / 'tests' / 'fixtures' / 'sample_mod'
LUAJIT = support.LUAJIT
EXPECT_RE = re.compile(r'expect:\s*((?:R\d+\s*)+)')


def marked(include_tests: bool) -> set[tuple[str, str, int]]:
    """(rule, file, line) for every `expect:` marker in the fixture repo."""
    result = set()
    for folder in ['src'] + (['tests'] if include_tests else []):
        for path in sorted((FIXTURE / folder).glob('*.lua')):
            for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
                match = EXPECT_RE.search(line)
                for rule in (match.group(1).split() if match else []):
                    result.add((rule, path.relative_to(FIXTURE).as_posix(), number))
    return result


def fixture_repo(path: Path = FIXTURE) -> lint.Repo:
    return lint.Repo('SampleMod', path, ['src/**/*.lua'], ['tests/**/*.lua'], frozenset({'SampleMod'}))


def found(result: lint.Scan) -> set[tuple[str, str, int]]:
    return {(v.rule, v.file, v.line) for v in result.violations}


def run(*argv: str) -> tuple[int, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = lint.main(list(argv))
    return code, out.getvalue() + err.getvalue()


@support.needs_luajit
class RuleTests(unittest.TestCase):
    def test_sources_report_exactly_the_marked_lines(self):
        result = lint.scan([fixture_repo()], LUAJIT, include_tests=False)
        self.assertEqual(found(result), marked(False))

    def test_fixtures_cover_every_rule(self):
        self.assertEqual({rule for rule, _, _ in marked(False)}, set(lint.RULES))

    def test_tests_flag_adds_r1_to_r7_for_test_files(self):
        result = lint.scan([fixture_repo()], LUAJIT, include_tests=True)
        self.assertEqual(found(result), marked(True))
        test_rules = {v.rule for v in result.violations if v.kind == 'test'}
        self.assertEqual(test_rules, {'R1', 'R4'})  # the R8 and R9 lines in the test file stay silent
        self.assertTrue(test_rules <= lint.TEST_RULES)

    def test_suppressed_lines(self):
        result = lint.scan([fixture_repo()], LUAJIT, include_tests=False)
        self.assertEqual({(v.rule, v.file) for v in result.suppressed},
                         {('R1', 'src/r1_cdef.lua'), ('R8', 'src/r8_globals.lua')})

    def test_details_name_the_problem(self):
        result = lint.scan([fixture_repo()], LUAJIT, include_tests=False)
        details = {(v.file, v.line): v.detail for v in result.violations}
        self.assertIn('GetTickCount: __asm__ label repeats the global name', details[('src/r1_cdef.lua', 11)])
        self.assertIn('not a string literal', details[('src/r1_cdef.lua', 23)])
        self.assertIn("'_'", details[('src/r8_globals.lua', 12)])
        self.assertIn("'selected'", details[('src/r8_globals.lua', 12)])
        self.assertIn("BYTES = ffi.cast('uint8_t *'", details[('src/r3_raw_store.lua', 9)])
        self.assertIn('function-pointer type', details[('src/r2_type_string.lua', 8)])

    def test_one_violation_per_rule_and_line(self):
        result = lint.scan([fixture_repo()], LUAJIT, include_tests=False)
        keys = [(v.rule, v.file, v.line) for v in result.violations]
        self.assertEqual(len(keys), len(set(keys)))

    def test_lint_ok_needs_the_rule_and_a_reason(self):
        text = ('local a = os.clock() -- lint-ok: R6\n'
                'local b = os.clock() -- lint-ok: R5 wrong rule\n'
                'local c = os.clock() -- lint-ok: R5, R6 both listed\n'
                'local d = os.clock() -- lint-ok: R6 timing only in a test build\n')
        kept, dropped = lint.scan_text(fixture_repo(), 'src/x.lua', text, 'source', [])
        self.assertEqual([v.line for v in kept], [1, 2])
        self.assertEqual([v.line for v in dropped], [3, 4])

    def test_strings_and_comments_are_not_code(self):
        text = ("local s = 'jit.flush() os.clock() collectgarbage()' -- jit.flush() os.clock()\n"
                "--[[ ffi.cast('float *', p)[0] = 1 ]] local t = [==[ pcall(previous, 1) ]==]\n")
        kept, _ = lint.scan_text(fixture_repo(), 'src/x.lua', text, 'source', [])
        self.assertEqual(kept, [])

    def test_gset_lister_reads_compiled_bytecode(self):
        path = FIXTURE / 'src' / 'r8_globals.lua'
        writes = lint.global_writes(LUAJIT, [path])[str(path)]
        self.assertEqual(sorted(writes), [(4, 'update'), (5, 'shutdown'), (6, 'SampleMod'),
                                          (12, '_'), (12, 'selected'), (15, 'helper')])

    def test_c_prototypes(self):
        problems = [p for _, _, p in lint.c_prototypes(
            'typedef void (__stdcall *Callback)(int);\n'
            'int (__stdcall *pointer_variable)(int);\n'
            'struct S { void (*f)(void); };\n'
            '#pragma pack(push, 1)\n'
            'unsigned long __stdcall Exported(void *a, int b) __attribute__((aligned(16)));\n'
            'void *private_name(void) __asm__("Exported2");\n'
            'int first(void), second(int) __asm__("second");\n')]
        self.assertEqual(problems, ['Exported: global prototype without an __asm__ label',
                                    'first: global prototype without an __asm__ label',
                                    'second: __asm__ label repeats the global name'])


@support.needs_luajit
class BaselineTests(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix='bingus-lint-'))
        self.repo = self.temp / 'sample_mod'
        shutil.copytree(FIXTURE, self.repo)
        self.config = self.temp / 'repos.json'
        self.write_config([('SampleMod', self.repo)])
        self.baseline = self.temp / 'baseline.json'

    def tearDown(self):
        shutil.rmtree(self.temp, ignore_errors=True)

    def write_config(self, repos):
        self.config.write_text(json.dumps({'luajit': str(LUAJIT), 'repos': [
            {'name': name, 'path': str(path), 'sources': ['src/**/*.lua'], 'allowed_globals': ['SampleMod']}
            for name, path in repos]}), encoding='utf-8')

    def lint(self, *argv: str) -> tuple[int, str]:
        return run(*argv, '--config', str(self.config), '--baseline', str(self.baseline))

    def edit(self, rel: str, old: str, new: str, root: Path | None = None):
        path = (root or self.repo) / rel
        text = path.read_text(encoding='utf-8')
        self.assertIn(old, text)
        path.write_text(text.replace(old, new, 1), encoding='utf-8')

    def entries(self):
        return json.loads(self.baseline.read_text(encoding='utf-8'))['entries']

    def test_first_baseline_needs_allow_increase(self):
        code, out = self.lint('update')
        self.assertEqual(code, 1, out)
        self.assertIn('refused', out)
        self.assertFalse(self.baseline.exists())
        code, out = self.lint('update', '--allow-increase')
        self.assertEqual(code, 0, out)
        entries = self.entries()
        self.assertEqual(len(entries), len(marked(False)), 'one identity per marked line')
        counted = [e for e in entries if e['rule'] not in lint.STRUCTURE_RULES]
        self.assertEqual(sum(e['count'] for e in counted), len([m for m in marked(False)
                                                               if m[0] not in lint.STRUCTURE_RULES]))
        def measured(rule, file):
            return sum(e['count'] for e in entries if (e['rule'], e['file']) == (rule, file))
        self.assertEqual(measured('R12', 'src/r12_parameters.lua'), 8 + 8, 'two functions with 8 each')
        self.assertEqual(measured('R15', 'src/r15_module_size.lua'), 1001)
        self.assertEqual(measured('R10', 'src/r10_cognitive.lua'), 16 + 16)

    def test_a_function_getting_worse_fails_check(self):
        # The baseline holds measured values for R10-R15, so a known violation may not grow.
        self.lint('update', '--allow-increase')
        self.edit('src/r10_cognitive.lua', "    repeat d = nil until a and b or c -- one more",
                  "    if d then d = 0 end\n    repeat d = nil until a and b or c -- one more")
        code, out = self.lint('check')
        self.assertEqual(code, 1, out)
        self.assertIn('NEW R10 cognitive-complexity  SampleMod src/r10_cognitive.lua', out)
        self.assertIn('(baseline 16, now 17)', out)
        self.assertIn('cognitive complexity 17 (limit 15)', out)

    def test_a_function_getting_better_is_reported_fixed(self):
        self.lint('update', '--allow-increase')
        self.edit('src/r10_cognitive.lua', "    repeat d = nil until a and b or c -- one more",
                  "    repeat d = nil until a -- one more")
        code, out = self.lint('check')
        self.assertEqual(code, 0, out)
        self.assertIn('fixed - run update: R10 cognitive-complexity  SampleMod src/r10_cognitive.lua', out)

    def test_limits_come_from_the_config(self):
        config = json.loads(self.config.read_text(encoding='utf-8'))
        config['limits'] = {'cognitive': 16, 'parameters': 8}
        self.config.write_text(json.dumps(config), encoding='utf-8')
        code, out = self.lint('scan', '--list')
        self.assertEqual(code, 0, out)
        self.assertNotIn('M.sixteen', out)
        self.assertNotIn('R12 parameters', out)
        self.assertIn('R11 function-size', out, 'other limits keep their defaults')
        config['limits'] = {'cognitive': 16, 'speed': 1}
        self.config.write_text(json.dumps(config), encoding='utf-8')
        code, out = self.lint('scan')
        self.assertEqual(code, 2, out)
        self.assertIn('unknown limits', out)

    def test_vendored_copies_are_not_duplicates(self):
        # A file kept byte-identical to a canonical copy on purpose is left out of R14.
        source = self.repo / 'src' / 'r14_shared_b.lua'
        source.rename(self.repo / 'src' / 'bingus_text.lua')
        code, out = self.lint('scan', '--list')
        self.assertEqual(code, 0, out)
        self.assertNotIn('R14 duplicated-code', out)

    def test_check_passes_against_its_own_baseline(self):
        self.lint('update', '--allow-increase')
        code, out = self.lint('check')
        self.assertEqual(code, 0, out)
        self.assertIn('0 new, 0 fixed', out)

    def test_new_violation_fails_check(self):
        self.lint('update', '--allow-increase')
        self.edit('src/r6_clock.lua', 'return M\n', 'M.started = os.clock()\nreturn M\n')
        code, out = self.lint('check')
        self.assertEqual(code, 1, out)
        self.assertIn('NEW R6 os-clock  SampleMod src/r6_clock.lua:10', out)
        self.assertIn('1 new', out)

    def test_another_copy_of_a_known_line_is_new(self):
        self.lint('update', '--allow-increase')
        self.edit('src/r4_gc.lua', "    collectgarbage() -- expect: R4\n",
                  "    collectgarbage() -- expect: R4\n    collectgarbage() -- expect: R4\n")
        code, out = self.lint('check')
        self.assertEqual(code, 1, out)
        self.assertIn('(baseline 1, now 2)', out)

    def test_fixed_violation_is_reported_then_removed_by_update(self):
        self.lint('update', '--allow-increase')
        self.edit('src/r6_clock.lua', 'local clock = os.clock -- expect: R6', 'local clock = os.time')
        code, out = self.lint('check')
        self.assertEqual(code, 0, out)
        self.assertIn('fixed - run update: R6 os-clock  SampleMod src/r6_clock.lua', out)
        before = sum(e['count'] for e in self.entries())
        code, out = self.lint('update')
        self.assertEqual(code, 0, out)
        self.assertEqual(sum(e['count'] for e in self.entries()), before - 1)
        code, out = self.lint('check')
        self.assertNotIn('fixed - run update', out)

    def test_update_refuses_increases_unless_allowed(self):
        self.lint('update', '--allow-increase')
        before = self.baseline.read_text(encoding='utf-8')
        self.edit('src/r4_gc.lua', 'return M\n', "collectgarbage('stop')\nreturn M\n")
        code, out = self.lint('update')
        self.assertEqual(code, 1, out)
        self.assertIn('INCREASE R4 gc-mutation', out)
        self.assertEqual(self.baseline.read_text(encoding='utf-8'), before)
        code, out = self.lint('update', '--allow-increase')
        self.assertEqual(code, 0, out)
        self.assertEqual(self.lint('check')[0], 0)

    def test_repo_override_lints_a_working_branch(self):
        self.lint('update', '--allow-increase')
        branch = self.temp / 'branch'
        shutil.copytree(self.repo, branch)
        self.edit('src/r5_jit.lua', 'return M\n', 'jit.flush()\nreturn M\n', root=branch)
        code, out = self.lint('check', '--repo', f'SampleMod={branch}')
        self.assertEqual(code, 1, out)
        self.assertIn('NEW R5 jit-global', out)
        self.assertEqual(self.lint('check')[0], 0)  # the configured checkout is unchanged

    def test_only_limits_scan_check_and_update(self):
        other = self.temp / 'other_mod'
        shutil.copytree(FIXTURE, other)
        self.write_config([('SampleMod', self.repo), ('OtherMod', other)])
        self.lint('update', '--allow-increase')
        self.edit('src/r6_clock.lua', 'return M\n', 'M.started = os.clock()\nreturn M\n', root=other)
        self.assertEqual(self.lint('check', '--only', 'SampleMod')[0], 0,
                         'duplicated code is found across every configured repo, whatever --only selects')
        self.assertEqual(self.lint('check')[0], 1)
        code, out = self.lint('scan', '--only', 'SampleMod')
        self.assertNotIn('OtherMod', out)

    def test_test_entries_are_outside_a_source_only_check(self):
        self.lint('update', '--allow-increase', '--tests')
        self.assertTrue(any(e['kind'] == 'test' for e in self.entries()))
        code, out = self.lint('check')
        self.assertEqual(code, 0, out)
        self.assertNotIn('fixed - run update', out)
        self.assertEqual(self.lint('update')[0], 0)
        self.assertTrue(any(e['kind'] == 'test' for e in self.entries()))  # kept

    def test_compile_error_is_an_error_not_a_pass(self):
        self.edit('src/r6_clock.lua', 'return M\n', 'local = 1\nreturn M\n')
        code, out = self.lint('scan')
        self.assertEqual(code, 2, out)
        self.assertIn('cannot compile', out)

    def test_json_output(self):
        code, out = self.lint('scan', '--json')
        self.assertEqual(code, 0)
        data = json.loads(out)
        self.assertEqual(sum(data['summary']['SampleMod'].values()), len(data['violations']))
        self.assertEqual({(v['rule'], v['file'], v['line']) for v in data['violations']}, marked(False))
        self.assertEqual(data['rules']['R3'], 'raw-store')

    def test_summary_table(self):
        code, out = self.lint('scan')
        self.assertEqual(code, 0)
        header, row = out.splitlines()[:2]
        self.assertTrue(header.split()[1:] == list(lint.RULES) + ['total'])
        counts = [int(x) for x in row.split()[1:]]
        self.assertEqual(counts[-1], len(marked(False)))


if __name__ == '__main__':
    unittest.main()
