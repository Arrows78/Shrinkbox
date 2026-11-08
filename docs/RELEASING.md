# Releasing

Versions and the changelog come from the git history: nothing is written by hand except commit messages.
`scripts/release.py` does the rest. The version lives in `Resources/Info.plist`.

## Commit messages

Commits follow [Conventional Commits](https://www.conventionalcommits.org): `type(scope): description`.

| Type | In changelog | Version bump |
| --- | --- | --- |
| `feat` | Added | minor |
| `fix` | Fixed | patch |
| `perf`, `refactor` | Changed | patch |
| `docs`, `test`, `ci`, `build`, `chore`, `style` | not listed | none |
| any type with `!`, or a `BREAKING CHANGE:` line | marked **BREAKING** | major (minor while the version is 0.x) |

Write the description for a user of the app, in the imperative ("add curved arrows", not "added curved arrows"):
it ends up in the changelog as is. CI checks the subjects of pull requests (`release.py lint`).

## Releasing

```sh
python3 scripts/release.py prepare --dry-run    # which version, which entries
python3 scripts/release.py prepare              # bumps Resources/Info.plist, rewrites CHANGELOG.md
git add -A && git commit -m "chore(release): 1.1.0"      # or run prepare with --commit
git tag v1.1.0 && git push origin main v1.1.0
```

- `prepare` picks the next version from the commits since the last `v*` tag; `--version X` forces one (use it
  for the very first release, `--version 1.0.0`). It refuses when no commit belongs in a release. The build
  number goes up by one.
- The tag triggers `.github/workflows/release.yml`: version and changelog checks, universal build, self-test,
  GitHub release with the zip and its SHA-256.
- The release notes are `docs/releases/<version>.md` when that file exists (use it for hand-written text), the
  changelog section of the version otherwise.

### One click, from GitHub

**Actions › Prepare release › Run workflow** (on `main`) does all of the above on GitHub: it checks the commit messages, runs
`release.py prepare` (the version comes from the commits, or from the *version* field to force one, e.g. a patch release),
commits `chore(release): X.Y.Z`, tags, pushes, and runs the release workflow on that tag. It refuses to run when no commit since
the last tag belongs in a release. Pushing a tag by hand still works the same as before.

## What CI guards

`python3 scripts/release.py check` (run by `scripts/ci.sh`, so by CI and by the release workflow) fails when:

- the version in `Resources/Info.plist` is behind the last tag, or has no section in `CHANGELOG.md`;
- the section of a released version no longer matches what the history produces;
- the section of the upcoming version is stale: commits were added after `prepare` (run `prepare` again).

## Notes

- `CHANGELOG.md` is regenerated whole from the tags: never edit it by hand. Dates are ignored when comparing.
- The first release is listed as "Initial release" instead of its commits.
- Only `v<major>.<minor>.<patch>` tags count. A tag pushed without a version bump makes the release workflow fail
  at its first check; delete it (`git push origin --delete vX.Y.Z`) and tag again once the version is bumped.

## Signing

macOS ties privacy permissions (screen recording, accessibility…) to the identity an app is signed with. A release signed ad hoc has a
new identity every time, so macOS forgets the permissions at each update. The release workflow therefore signs with the same
self-signed certificate as local builds, **Shrinkbox Local Signing**, when two repository secrets exist:

- `SHRINKBOX_SIGNING_P12`: the certificate with its private key, exported from Keychain Access as a `.p12` and base64 encoded;
- `SHRINKBOX_SIGNING_PASSWORD`: the password chosen at export.

```sh
base64 -i "Shrinkbox Local Signing.p12" | gh secret set SHRINKBOX_SIGNING_P12 --repo Arrows78/Shrinkbox
gh secret set SHRINKBOX_SIGNING_PASSWORD --repo Arrows78/Shrinkbox
```

Delete the exported file afterwards. `scripts/ci_import_identity.sh` imports the identity into a temporary keychain, the build is signed with
it and a step fails the release if the result is still ad hoc. Without the secrets the release is still published, signed ad hoc, with a notice.
Keep a safe copy of the `.p12`: with a different certificate every user has to grant the permissions once more.
The certificate is self-signed, so macOS still blocks the first launch (open it with **Open Anyway**); only a Developer ID and notarisation remove that.

## Homebrew tap

The tap is the public repository `Arrows78/homebrew-shrinkbox`. The release workflow rewrites `Casks/shrinkbox.rb` in it after publishing a release,
from `packaging/homebrew/shrinkbox.rb.in` and the SHA-256 of the zip (`scripts/render_cask.sh`).

- One-time setup: create a fine-grained personal access token limited to **only** `Arrows78/homebrew-shrinkbox` with the permission
  **Contents: read and write**, then store it as the `HOMEBREW_TAP_SHRINKBOX_TOKEN` secret of this repository
  (`gh secret set HOMEBREW_TAP_SHRINKBOX_TOKEN --repo Arrows78/Shrinkbox`).
- Without that secret the release is still published and the tap is left alone (the workflow only prints a notice).
- The cask is never edited by hand: fix the template and release again.
