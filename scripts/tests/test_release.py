"""Tests of scripts/release.py. Run: python3 -m unittest discover -s scripts/tests"""
import contextlib
import io
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import release  # noqa: E402

C = release.Commit


class SubjectTests(unittest.TestCase):
    def test_parses_type_scope_and_description(self):
        c = C('feat(editor): add curved arrows')
        self.assertEqual((c.type, c.scope, c.description), ('feat', 'editor', 'add curved arrows'))
        self.assertFalse(c.breaking)

    def test_scope_is_optional(self):
        self.assertEqual((C('ci: run the tests').type, C('ci: run the tests').scope), ('ci', None))

    def test_a_bang_or_a_body_marks_a_breaking_change(self):
        self.assertTrue(C('feat(api)!: drop the old format').breaking)
        self.assertTrue(C('fix: change the file format', 'BREAKING CHANGE: old files are not read').breaking)

    def test_a_free_form_subject_has_no_type(self):
        self.assertIsNone(C('Update readme').type)

    def test_lint(self):
        self.assertIsNone(release.lint_subject('fix(ocr): keep line breaks'))
        self.assertIsNone(release.lint_subject('Merge branch main'))
        self.assertIn('expected', release.lint_subject('Update readme'))
        self.assertIn('unknown type', release.lint_subject('wip: stuff'))
        self.assertIn('longer', release.lint_subject('fix: ' + 'x' * 100))


class VersionTests(unittest.TestCase):
    def test_bumps(self):
        self.assertEqual(release.bump_kind((1, 2, 3), [C('feat: a'), C('fix: b')]), 'minor')
        self.assertEqual(release.bump_kind((1, 2, 3), [C('fix: b'), C('docs: c')]), 'patch')
        self.assertEqual(release.bump_kind((1, 2, 3), [C('refactor: b')]), 'patch')
        self.assertIsNone(release.bump_kind((1, 2, 3), [C('docs: a'), C('ci: b'), C('build: c')]))
        self.assertEqual(release.bump_kind((1, 2, 3), [C('feat!: a')]), 'major')
        self.assertEqual(release.bump_kind((0, 2, 3), [C('feat!: a')]), 'minor')

    def test_bumped_resets_the_lower_numbers(self):
        self.assertEqual(release.bumped((1, 2, 3), 'minor'), (1, 3, 0))
        self.assertEqual(release.bumped((1, 2, 3), 'major'), (2, 0, 0))
        self.assertEqual(release.format_version((1, 3, 0)), '1.3.0')

    def test_a_malformed_version_is_refused(self):
        with self.assertRaises(ValueError):
            release.parse_version('1.2')


class ChangelogTests(unittest.TestCase):
    def test_entries_are_grouped_and_internal_types_left_out(self):
        found = release.entries([C('docs: readme'), C('fix(ocr): keep line breaks'), C('feat(editor): add curved arrows')])
        self.assertEqual(found['Added'], ['- **editor**: Add curved arrows'])
        self.assertEqual(found['Fixed'], ['- **ocr**: Keep line breaks'])
        self.assertEqual(found['Changed'], [])

    def test_section_render_and_lookup(self):
        text = release.render_section('1.1.0', '2026-01-01', [C('feat: add x')]) + '\n## [1.0.0] - 2025-01-01\n\n- old\n'
        self.assertEqual(release.section_of(text, '1.1.0'), '### Added\n\n- Add x\n')
        self.assertIsNone(release.section_of(text, '9.9.9'))

    def test_dates_are_ignored_when_comparing(self):
        a, b = '## [1.0.0] - 2026-01-01\n\n- x\n', '## [1.0.0] - 2026-02-02\n\n- x\n'
        self.assertEqual(release.without_dates(a), release.without_dates(b))

    def test_initial_release(self):
        self.assertIn('Initial release', release.render_section('1.0.0', '2026-01-01', [], initial=True))


class PlistTests(unittest.TestCase):
    def test_version_is_read_and_written_keeping_key_order(self):
        raw = plistlib.dumps({'CFBundleName': 'Shrinkbox', 'CFBundleShortVersionString': '1.0.0', 'CFBundleVersion': '1', 'Z': 1}, sort_keys=False)
        self.assertEqual(release.project_version(raw), ('1.0.0', '1'))
        out = release.set_plist_version(raw, '1.1.0', '2')
        self.assertEqual(release.project_version(out), ('1.1.0', '2'))
        self.assertEqual(list(plistlib.loads(out)), ['CFBundleName', 'CFBundleShortVersionString', 'CFBundleVersion', 'Z'])


class RepoTests(unittest.TestCase):
    """prepare / check against a throw-away git repository."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        (self.root / 'Resources').mkdir()
        (self.root / 'Resources/Info.plist').write_bytes(
            plistlib.dumps({'CFBundleShortVersionString': '1.0.0', 'CFBundleVersion': '1'}, sort_keys=False))
        for name, value in (('ROOT', self.root), ('CHANGELOG', self.root / 'CHANGELOG.md'), ('INFO_PLIST', self.root / 'Resources/Info.plist')):
            patcher = mock.patch.object(release, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.email', 't@example.com')
        self.git('config', 'user.name', 't')
        self.git('config', 'commit.gpgsign', 'false')

    def tearDown(self):
        self.dir.cleanup()

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.root, capture_output=True, text=True, check=True).stdout

    def commit(self, subject):
        self.git('commit', '-q', '--allow-empty', '-m', subject)

    def run_cmd(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = release.main(list(argv))
        return code, out.getvalue()

    def test_first_release_then_a_patch(self):
        self.commit('feat: first thing')
        self.assertEqual(self.run_cmd('prepare', '--version', '1.0.0')[0], 0)
        self.assertEqual(self.run_cmd('check')[0], 0)
        self.git('add', '-A')
        self.commit('chore(release): 1.0.0')
        self.git('tag', 'v1.0.0')
        self.assertEqual(self.run_cmd('check')[0], 0)
        self.commit('fix(ocr): keep line breaks')
        self.assertEqual(self.run_cmd('next')[1].strip(), '1.0.1')
        self.assertEqual(self.run_cmd('prepare')[0], 0)
        self.assertEqual(release.project_version(), ('1.0.1', '3'))
        self.assertEqual(self.run_cmd('check')[0], 0)
        self.assertIn('Keep line breaks', self.run_cmd('notes', '1.0.1')[1])

    def test_nothing_to_release(self):
        self.commit('docs: readme')
        self.assertEqual(self.run_cmd('prepare')[0], 1)

    def test_check_fails_without_a_changelog_section(self):
        self.commit('feat: a')
        code, out = self.run_cmd('check')
        self.assertEqual(code, 1)
        self.assertIn('no section', out)

    def test_check_catches_a_stale_changelog(self):
        self.commit('feat: a')
        self.run_cmd('prepare', '--version', '1.0.0')
        self.git('add', '-A')
        self.commit('chore(release): 1.0.0')
        self.git('tag', 'v1.0.0')
        self.commit('feat: b')
        self.run_cmd('prepare', '--version', '1.1.0')
        self.commit('fix: c')
        code, out = self.run_cmd('check')
        self.assertEqual(code, 1)
        self.assertIn('out of date for 1.1.0', out)

    def test_lint_range(self):
        self.commit('feat: ok')
        self.commit('feat: fine')
        self.commit('Update readme')
        code, out = self.run_cmd('lint', 'HEAD~2..HEAD')
        self.assertEqual(code, 1)
        self.assertIn('Update readme', out)


if __name__ == '__main__':
    unittest.main()
