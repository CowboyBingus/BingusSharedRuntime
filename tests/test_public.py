"""The repository is public: no user-profile paths, email addresses or private notes in any file.

Run: python -m unittest discover -s tests -v   (from the repository folder)
"""
import re
import unittest

import support

PATTERNS = {
    'a user-profile path': re.compile(r'[A-Za-z]:[\\/]+Users[\\/]', re.I),
    'an email address': re.compile(r'[\w.+-]+@[\w-]+\.[A-Za-z]{2,}'),
    'a knowledge-base reference': re.compile(r'\bKB [a-z0-9]+-[a-z0-9-]+|\bkb (?:show|new)\b'),
    'the old name of this repository': re.compile(r'\bResilience\b'),
}
SKIPPED_FOLDERS = {'.git', '__pycache__'}
DISCLOSURE = '**AI disclosure:** Claude Opus 5.5 assisted with research, implementation, tests and documentation.'


def files():
    for path in sorted(support.ROOT.rglob('*')):
        if path.is_file() and not SKIPPED_FOLDERS.intersection(path.relative_to(support.ROOT).parts):
            yield path


class PublicRepository(unittest.TestCase):
    def test_no_private_details(self):
        for path in files():
            text = path.read_bytes().decode('utf-8', errors='replace')
            for what, pattern in PATTERNS.items():
                found = pattern.search(text)
                with self.subTest(file=path.relative_to(support.ROOT).as_posix(), check=what):
                    self.assertIsNone(found, f'{what}: {found.group() if found else ""}')

    def test_readme_names_the_project_and_discloses_ai_help(self):
        readme = (support.ROOT / 'README.md').read_text(encoding='utf-8')
        self.assertTrue(readme.startswith('# Bingus Shared Runtime\n'))
        self.assertEqual(readme.count(DISCLOSURE), 1)

    def test_license_is_zero_clause_bsd(self):
        # 0BSD: use, copy, modify and distribute for any purpose, no conditions.
        text = (support.ROOT / 'LICENSE').read_text(encoding='utf-8')
        self.assertIn('BSD Zero Clause License', text)
        self.assertIn('Copyright (C) 2026 by CowboyBingus', text)


if __name__ == '__main__':
    unittest.main()
