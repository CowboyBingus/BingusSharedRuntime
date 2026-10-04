"""Tests for metrics.py: cognitive complexity against SonarSource's examples, LuaJIT's local
count, function facts and duplicated-code regions.

Run: python -m unittest discover -s tests -v   (from the repository folder)
"""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import lint  # noqa: E402
import metrics  # noqa: E402


def functions(source: str) -> dict[str, metrics.Function]:
    _, found = metrics.analyse(lint.tokenize(source))
    return {function.name: function for function in found}


def complexity(source: str) -> int:
    (function,) = functions(source).values()
    return function.cognitive


class CognitiveComplexity(unittest.TestCase):
    def test_sonar_sum_of_primes_is_7(self):
        # SonarSource's white paper, Java with `continue OUT`; in Lua a goto.
        self.assertEqual(complexity("""
            local function sum_of_primes(max)
              local total = 0
              for i = 1, max do            -- +1
                for j = 2, i - 1 do        -- +2
                  if i % j == 0 then       -- +3
                    goto continue          -- +1
                  end
                end
                total = total + i
                ::continue::
              end
              return total
            end"""), 7)

    def test_if_elseif_else_chain(self):
        self.assertEqual(complexity("""
            local function words(n)
              if n == 1 then return 'one'      -- +1
              elseif n == 2 then return 'two'  -- +1
              elseif n == 3 then return 'few'  -- +1
              else return 'lots' end           -- +1
            end"""), 4)

    def test_else_branches_do_not_nest_but_their_contents_do(self):
        self.assertEqual(complexity("""
            local function f(a, b, c)
              if a then           -- +1
                if b then end     -- +2
              elseif c then       -- +1
                if b then end     -- +2
              else                -- +1
                if c then end     -- +2
              end
            end"""), 9)

    def test_runs_of_boolean_operators(self):
        self.assertEqual(complexity("local function f(a, b, c) return a and b and c end"), 1)
        self.assertEqual(complexity("local function f(a, b, c, d, e) return a and b and c or d and e end"), 3)
        self.assertEqual(complexity("local function f(a, b, c, d) return a and f(b and c) and d end"), 2 + 1,
                         'the call is recursion: +1')
        self.assertEqual(complexity("local function f(a, b, c, d) return a and g(b and c) and d end"), 2)
        self.assertEqual(complexity("local function f(a, b, c) return a and (b or c) end"), 2)
        self.assertEqual(complexity("local function f(a, b, c, d) return a or g(b and c) or d end"), 2,
                         'the bracket keeps the outer or-run going')
        self.assertEqual(complexity("local function f(t, a, b) return a and t[b and 1] and b end"), 2)
        self.assertEqual(complexity("local function f(a, b) local x = a and b; return a and b end"), 2,
                         'a statement boundary starts a new run')

    def test_not_and_comparisons_continue_a_run(self):
        self.assertEqual(complexity("local function f(a, b, c) return not a and b == 1 and c ~= nil end"), 1)

    def test_loops_and_repeat_nest(self):
        self.assertEqual(complexity("""
            local function f(t)
              while true do               -- +1
                for _, v in ipairs(t) do  -- +2
                  repeat                  -- +3
                    v = v - 1
                  until v <= 0
                end
              end
            end"""), 6)

    def test_break_is_free_and_goto_costs_one(self):
        self.assertEqual(complexity("local function f() while true do break end end"), 1)
        self.assertEqual(complexity("local function f() goto done ::done:: end"), 1)

    def test_recursion_counts_once(self):
        self.assertEqual(complexity("local function fact(n) if n <= 1 then return 1 end return n * fact(n - 1) * fact(1) end"), 2)
        self.assertEqual(complexity("local t = {} function t.walk(n) return n and t.walk(n - 1) end"), 1,
                         't.walk(...) is a field call, not the local name; only the and run counts')

    def test_closures_are_measured_on_their_own(self):
        found = functions("""
            local function factory(flag)
              if flag then end                 -- the factory: +1
              local function inner(a)
                if a then if a then end end    -- inner: +1, +2 (its own nesting starts at 0)
              end
              return function(b) return b and inner(b) or nil end   -- anonymous: and, or
            end""")
        self.assertEqual(found['factory'].cognitive, 1)
        self.assertEqual(found['inner'].cognitive, 3)
        self.assertEqual(found['<anonymous>'].cognitive, 2)
        self.assertEqual(found['inner'].nesting, 2)


class FunctionFacts(unittest.TestCase):
    def test_names_lines_and_parameters(self):
        found = functions("""local M = {}
function M.f(a, b) return a end
function M:g(a) return self end
local h = function(a, ...) return a end
local t = {k = function() end}
return M""")
        self.assertEqual((found['M.f'].line, found['M.f'].end, found['M.f'].parameters), (2, 2, 2))
        self.assertEqual(found['M.g'].parameters, 2, 'self counts')
        self.assertEqual((found['h'].parameters, found['h'].vararg), (1, True), '... does not count')
        self.assertEqual(found['k'].line, 5)

    def test_code_lines_skip_blank_and_comment_lines(self):
        found = functions("""local function f()
  -- a comment

  return 1
end""")
        self.assertEqual(len(found['f'].lines), 3)

    def test_code_lines_leave_nested_functions_out(self):
        found = functions("""local function outer()
  local function inner()
    return 1
  end
  return inner
end""")
        self.assertEqual(sorted(found['outer'].lines), [1, 2, 5, 6], 'a nested function only on its first line')
        self.assertEqual(sorted(found['inner'].lines), [2, 3, 4])


class ActiveLocals(unittest.TestCase):
    """LuaJIT allows 200 active locals per function: parameters, locals and hidden loop variables."""

    def test_for_loops_add_three_hidden_variables(self):
        found = functions("""local function f(n)
  for i = 1, n do
    for k, v in pairs(n) do
    end
  end
end""")
        self.assertEqual(found['f'].active_locals, 1 + (3 + 1) + (3 + 2))

    def test_branches_and_blocks_release_their_locals(self):
        found = functions("""local function f(a)
  if a then
    local x, y, z = 1, 2, 3
  else
    local w = 4
  end
  do local q = 1 end
  local r = 2
end""")
        self.assertEqual(found['f'].active_locals, 1 + 3)
        self.assertEqual(found['f'].active_line, 3)

    def test_the_main_chunk_counts_its_top_level_locals(self):
        main, _ = metrics.analyse(lint.tokenize("local a, b = 1, 2\nlocal function f() local c end\nlocal d"))
        self.assertEqual(main.active_locals, 4, 'a, b, f and d; c belongs to f')


class Duplicates(unittest.TestCase):
    def tokens(self, text: str):
        return [t for t in lint.tokenize(text) if t.kind != 'eof']

    def test_a_shared_block_is_one_region_per_file(self):
        shared = ' '.join(f'x{n} = x{n} + {n}' for n in range(30))   # 150 tokens
        first = self.tokens('local a = 1\n' + shared + '\nreturn a')
        second = self.tokens('local b = {}\n' + shared + '\nlocal z = b')
        clones = metrics.duplicates([first, second], 100)
        self.assertEqual(len(clones), 2)
        for clone in clones:
            self.assertEqual(clone.end - clone.start, 150)
            self.assertNotEqual(clone.file, clone.other_file)

    def test_overlapping_repeats_in_one_file_are_not_duplicates(self):
        # 150 tokens with a period of 15: equal windows overlap, so nothing is copied.
        text = self.tokens(' '.join(f'y = y + {n % 3}' for n in range(30)))
        self.assertEqual(metrics.duplicates([text], 100), [])

    def test_a_repeated_block_in_one_file_is_a_duplicate(self):
        block = ' '.join(f'y{n} = y{n} + {n}' for n in range(25))   # 125 tokens
        text = self.tokens(block + ' local gap = 1 ' + block)
        clones = metrics.duplicates([text], 100)
        self.assertEqual([(c.start, c.end - c.start, c.other_start) for c in clones], [(0, 125, 129), (129, 125, 0)],
                         'each copy is its own region and names the other')

    def test_shorter_than_the_limit_is_ignored(self):
        shared = ' '.join(f'x{n} = {n}' for n in range(20))   # 60 tokens
        self.assertEqual(metrics.duplicates([self.tokens(shared + ' a()'), self.tokens(shared + ' b()')], 100), [])


if __name__ == '__main__':
    unittest.main()
