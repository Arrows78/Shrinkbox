#!/usr/bin/env python3
"""Release tooling: version, changelog and release notes, all derived from the git history. See docs/RELEASING.md.

    release.py next                       the next version, from the commits since the last v* tag
    release.py prepare [--version X]      bump the version, update CHANGELOG.md (and commit with --commit)
    release.py changelog                  print the CHANGELOG.md the history produces
    release.py notes VERSION              print the changelog section of VERSION (the body of the GitHub release)
    release.py check                      verify that versions and changelog agree with the tags (used by CI)
    release.py lint RANGE                 verify that the commit subjects of RANGE are Conventional Commits

Commits follow Conventional Commits: the type decides the bump (feat: minor, fix, perf and refactor: patch, a
breaking change: major, or minor while the major version is 0) and the section of the changelog.
"""
import argparse
import datetime
import plistlib
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHANGELOG = ROOT / 'CHANGELOG.md'
INFO_PLIST = ROOT / 'Resources/Info.plist'
DEFAULT_REPO_URL = 'https://github.com/Arrows78/Shrinkbox'

TYPES = ('feat', 'fix', 'perf', 'refactor', 'docs', 'test', 'ci', 'build', 'chore', 'style', 'revert')
SUBJECT = re.compile(r'^(?P<type>[a-z]+)(?:\((?P<scope>[^)]+)\))?(?P<bang>!)?: (?P<description>\S.*)$')
MAX_SUBJECT = 100
TAG = re.compile(r'^v(\d+)\.(\d+)\.(\d+)$')

# Changelog sections, in display order, and the commit types that feed them. Other types stay out of the changelog.
SECTIONS = (('Added', ('feat',)), ('Changed', ('perf', 'refactor')), ('Fixed', ('fix',)))
SECTION_OF = {t: name for name, types in SECTIONS for t in types}


@dataclass(frozen=True)
class Commit:
    subject: str
    body: str = ''

    @property
    def parsed(self):
        return SUBJECT.match(self.subject)

    @property
    def type(self):
        m = self.parsed
        return m.group('type') if m else None

    @property
    def scope(self):
        m = self.parsed
        return m.group('scope') if m else None

    @property
    def description(self):
        m = self.parsed
        return m.group('description') if m else self.subject

    @property
    def breaking(self):
        m = self.parsed
        return bool(m and m.group('bang')) or 'BREAKING CHANGE:' in self.body or 'BREAKING-CHANGE:' in self.body


# ---------------------------------------------------------------------------------------------------- versions

def parse_version(text):
    m = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)', text)
    if not m:
        raise ValueError(f'not a version: {text!r}')
    return tuple(int(x) for x in m.groups())


def format_version(v):
    return '.'.join(str(x) for x in v)


def bump_kind(current, commits):
    """'major', 'minor', 'patch' or None when nothing in the commits belongs in a release."""
    if any(c.breaking for c in commits):
        return 'minor' if current[0] == 0 else 'major'
    if any(c.type == 'feat' for c in commits):
        return 'minor'
    if any(c.type in ('fix', 'perf', 'refactor') for c in commits):
        return 'patch'
    return None


def bumped(current, kind):
    major, minor, patch = current
    return {'major': (major + 1, 0, 0), 'minor': (major, minor + 1, 0), 'patch': (major, minor, patch + 1)}[kind]


# ---------------------------------------------------------------------------------------------------- git

def git(*args):
    return subprocess.run(['git', *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout


def release_tags():
    """The v<major>.<minor>.<patch> tags, oldest first."""
    found = [t for t in git('tag', '--list', 'v*').split() if TAG.match(t)]
    return sorted(found, key=lambda t: parse_version(t[1:]))


def commits_in(rev_range):
    out = git('log', '--no-merges', '--format=%s%x1f%b%x1e', rev_range)
    commits = []
    for record in out.split('\x1e'):
        record = record.strip('\n')
        if record.strip():
            subject, _, body = record.partition('\x1f')
            commits.append(Commit(subject.strip(), body.strip()))
    return commits


def tag_date(tag):
    return git('log', '-1', '--format=%cs', tag).strip()


def repo_url():
    try:
        remote = git('remote', 'get-url', 'origin').strip()
    except subprocess.CalledProcessError:
        return DEFAULT_REPO_URL
    m = re.match(r'(?:git@github\.com:|https://github\.com/)(.+?)(?:\.git)?$', remote)
    return f'https://github.com/{m.group(1)}' if m else DEFAULT_REPO_URL


# ---------------------------------------------------------------------------------------------------- changelog

def entries(commits):
    """{section: [line, ...]} for the commits that belong in the changelog, in commit order (oldest first)."""
    result = {name: [] for name, _ in SECTIONS}
    for c in reversed(commits):
        section = SECTION_OF.get(c.type)
        if not section:
            continue
        text = c.description[0].upper() + c.description[1:]
        scope = f'**{c.scope}**: ' if c.scope else ''
        flag = '**BREAKING** ' if c.breaking else ''
        result[section].append(f'- {flag}{scope}{text}')
    return result


def render_section(version, date, commits, initial=False):
    lines = [f'## [{version}] - {date}', '']
    if initial:
        lines += ['### Added', '', '- Initial release.', '']
        return '\n'.join(lines)
    found = entries(commits)
    for name, _ in SECTIONS:
        if found[name]:
            lines += [f'### {name}', '', *found[name], '']
    if len(lines) == 2:
        lines += ['- Internal changes only.', '']
    return '\n'.join(lines)


def build_changelog(upcoming=None, today=None):
    """The whole CHANGELOG.md: one section per tag, plus `upcoming` (a version) for the commits since the last tag."""
    tags = release_tags()
    sections = []
    previous = None
    for tag in tags:
        rng = tag if previous is None else f'{previous}..{tag}'
        sections.append((tag[1:], previous, tag, render_section(tag[1:], tag_date(tag), commits_in(rng), initial=previous is None)))
        previous = tag
    if upcoming and (not tags or upcoming != tags[-1][1:]):
        date = today or datetime.date.today().isoformat()
        rng = f'{previous}..HEAD' if previous else 'HEAD'
        sections.append((upcoming, previous, 'HEAD', render_section(upcoming, date, commits_in(rng), initial=previous is None)))
    url = repo_url()
    body = '\n'.join(text for *_, text in reversed(sections))
    links = []
    for version, prev, ref, _ in reversed(sections):
        if prev is None:
            links.append(f'[{version}]: {url}/releases/tag/v{version}')
        else:
            links.append(f'[{version}]: {url}/compare/{prev}...v{version}')
    header = ('# Changelog\n\n'
              'All notable changes to Shrinkbox are listed here, newest first. The file is generated by `scripts/release.py`\n'
              'from the commit messages (Conventional Commits) and the `v*` tags: do not edit it by hand. See\n'
              '`docs/RELEASING.md`. Versions follow [Semantic Versioning](https://semver.org).\n\n')
    return header + body + '\n' + '\n'.join(links) + '\n'


def section_of(changelog, version):
    """The text of one version's section, without its heading line; None when there is none."""
    m = re.search(rf'^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|^\[[^\]]+\]: |\Z)', changelog, re.S | re.M)
    return m.group(1).strip('\n') + '\n' if m else None


def without_dates(text):
    return re.sub(r'^(## \[[^\]]+\]) - \d{4}-\d{2}-\d{2}$', r'\1', text, flags=re.M)


# ---------------------------------------------------------------------------------------------------- version files

def project_version(raw=None):
    """(version, build) read from the Info.plist, the single place the app version lives."""
    plist = plistlib.loads(INFO_PLIST.read_bytes() if raw is None else raw)
    try:
        return plist['CFBundleShortVersionString'], plist['CFBundleVersion']
    except KeyError:
        raise SystemExit('Info.plist has no CFBundleShortVersionString / CFBundleVersion')


def set_plist_version(raw, version, build):
    plist = plistlib.loads(raw)
    plist['CFBundleShortVersionString'] = version
    plist['CFBundleVersion'] = build
    return plistlib.dumps(plist, sort_keys=False)


# ---------------------------------------------------------------------------------------------------- commands

def current_context():
    tags = release_tags()
    last = tags[-1] if tags else None
    commits = commits_in(f'{last}..HEAD') if last else commits_in('HEAD')
    return last, commits


def cmd_next(_args):
    last, commits = current_context()
    current = parse_version(last[1:]) if last else (0, 0, 0)
    kind = bump_kind(current, commits)
    if not kind:
        print(f'nothing to release since {last}', file=sys.stderr)
        return 1
    print(format_version(bumped(current, kind)))
    return 0


def cmd_prepare(args):
    last, commits = current_context()
    current_project, build = project_version()
    if args.version:
        version = args.version.lstrip('v')
        parse_version(version)
    else:
        base = parse_version(last[1:]) if last else (0, 0, 0)
        kind = bump_kind(base, commits)
        if not kind:
            print(f'nothing to release since {last}: no feat, fix, perf or refactor commit (use --version to force)', file=sys.stderr)
            return 1
        version = format_version(bumped(base, kind))
    if last and parse_version(version) <= parse_version(last[1:]):
        print(f'{version} is not newer than the last tag {last}', file=sys.stderr)
        return 1
    new_build = str(int(build) + 1)
    changelog = build_changelog(upcoming=version)
    print(f'version {current_project} -> {version}, build {build} -> {new_build}')
    print(f'{sum(len(v) for v in entries(commits).values())} entries in the changelog since {last or "the start"}')
    if args.dry_run:
        print()
        print(section_of(changelog, version))
        return 0
    INFO_PLIST.write_bytes(set_plist_version(INFO_PLIST.read_bytes(), version, new_build))
    CHANGELOG.write_text(changelog)
    if args.commit:
        git('add', str(INFO_PLIST), str(CHANGELOG))
        git('commit', '-m', f'chore(release): {version}')
        print(f'committed chore(release): {version}')
    print(f'\nNext: review CHANGELOG.md, then  git tag v{version} && git push origin main v{version}')
    return 0


def cmd_changelog(_args):
    version, _ = project_version()
    tags = release_tags()
    sys.stdout.write(build_changelog(upcoming=None if tags and tags[-1][1:] == version else version))
    return 0


def cmd_notes(args):
    version = args.version.lstrip('v')
    text = CHANGELOG.read_text() if CHANGELOG.exists() else ''
    section = section_of(text, version)
    if section is None:
        print(f'CHANGELOG.md has no section for {version}: run scripts/release.py prepare', file=sys.stderr)
        return 1
    sys.stdout.write(section)
    return 0


def cmd_check(_args):
    problems = []
    version, build = project_version()
    tags = release_tags()
    if tags and parse_version(version) < parse_version(tags[-1][1:]):
        problems.append(f'Resources/Info.plist says {version}, behind the last tag {tags[-1]}')
    committed = CHANGELOG.read_text() if CHANGELOG.exists() else ''
    if section_of(committed, version) is None:
        problems.append(f'CHANGELOG.md has no section for {version} (the version of Resources/Info.plist)')
    upcoming = None if tags and tags[-1][1:] == version else version
    expected = build_changelog(upcoming=upcoming)
    for tag in tags:
        v = tag[1:]
        have, want = section_of(committed, v), section_of(expected, v)
        if have is None or without_dates(have) != without_dates(want):
            problems.append(f'CHANGELOG.md is out of date for {v}: run scripts/release.py prepare / regenerate it')
    if upcoming:
        have, want = section_of(committed, upcoming), section_of(expected, upcoming)
        if have is not None and without_dates(have) != without_dates(want):
            problems.append(f'CHANGELOG.md is out of date for {upcoming}: commits were added since it was prepared; '
                            f'run scripts/release.py prepare --version {upcoming}')
    if problems:
        print('\n'.join(problems))
        return 1
    print(f'Release files OK: version {version} (build {build}), {len(tags)} tag(s)')
    return 0


def lint_subject(subject):
    """None when the subject is a valid Conventional Commit, else the reason it is not."""
    if subject.startswith(('Merge ', 'Revert "')):
        return None
    m = SUBJECT.match(subject)
    if not m:
        return 'expected "type(scope): description"'
    if m.group('type') not in TYPES:
        return f'unknown type "{m.group("type")}" (use one of: {", ".join(TYPES)})'
    if len(subject) > MAX_SUBJECT:
        return f'subject longer than {MAX_SUBJECT} characters'
    return None


def cmd_lint(args):
    bad = []
    for c in commits_in(args.range):
        reason = lint_subject(c.subject)
        if reason:
            bad.append(f'  "{c.subject}": {reason}')
    if bad:
        print('Commit subjects that are not Conventional Commits:\n' + '\n'.join(bad))
        return 1
    print('Commit subjects OK')
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('next').set_defaults(run=cmd_next)
    p = sub.add_parser('prepare')
    p.add_argument('--version')
    p.add_argument('--dry-run', action='store_true')
    p.add_argument('--commit', action='store_true')
    p.set_defaults(run=cmd_prepare)
    sub.add_parser('changelog').set_defaults(run=cmd_changelog)
    p = sub.add_parser('notes')
    p.add_argument('version')
    p.set_defaults(run=cmd_notes)
    sub.add_parser('check').set_defaults(run=cmd_check)
    p = sub.add_parser('lint')
    p.add_argument('range')
    p.set_defaults(run=cmd_lint)
    args = parser.parse_args(argv)
    return args.run(args)


if __name__ == '__main__':
    sys.exit(main())
