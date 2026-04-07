# Nextcloud Release Agent

> [!WARNING]
> This project is vibe coded and has been audited but I'm no Ruby developer.  
> It doesn't have much weight but it does have my biases like squash preference, commit names, etc., ymmv.

Ruby CLI for releasing Nextcloud apps using `git` and `gh`.
It automates changelog updates, semver bumps, PR creation, tagging, releases, and workflow monitoring for Nextcloud app repositories.

## Requirements

- Ruby 3.1+
- `git` in `PATH`
- `gh` in `PATH` and logged in (`gh auth status`)

## Setup

- Target repo needs `appinfo/info.xml` and a `changelog.yaml` (see example file at `example/changelog.yaml`)
- The `release` remote is optional. If absent, tag push, GitHub release creation, and Actions monitoring are skipped for it with a warning.

## Install

```bash
gem install nextcloud_release_agent
```

User-local (no root):

```bash
gem install --user-install nextcloud_release_agent
export PATH="$(ruby -r rubygems -e 'print Gem.user_dir')/bin:$PATH"
```

Or without gem install:

```bash
git clone https://github.com/nextcloud/release_agent
ruby release_agent/exe/nextcloud-release-agent --help
```

## Usage

Prepare + publish in one shot
```bash
nextcloud-release-agent run --monitor
```

Create release PR only
```bash
nextcloud-release-agent prepare
```

Merge, tag, release
```bash
nextcloud-release-agent publish --monitor
```

Watch Github Actions for the latest version
```bash
nextcloud-release-agent monitor
```

Watch Github Actions for a specific version
```bash
nextcloud-release-agent monitor --repo translate2 2.4.0
```

## How it works

**`run`**

Runs `prepare` then `publish` in one shot. Use this for the happy path.

**`prepare`**

1. Fetch and sync the default branch.
2. Collect commits since the last `v*` tag.
3. Filter out commits matching `release_agent.ignore_commits` in `changelog.yaml`.
4. Fetch the GitHub PR for each commit.
5. Compute the next semver version.
6. Prepend a new changelog entry.
7. Render `CHANGELOG.md`.
8. Update `appinfo/info.xml` (and `<image-tag>` if present).
9. Create a `release/<version>` branch, commit, push, open a PR.

**`publish`**

1. Squash-merge the release PR (`--admin`), or wait for a manual merge.
2. Pull the merged default branch.
3. Create and push `v<version>` to `origin` and `release`.
4. Create GitHub releases in both remotes with the rendered changelog entry.
5. Optionally monitor the resulting GitHub Actions runs (`--monitor`).

## Semver

Version is derived from commit and PR metadata:

- **Major**: `BREAKING CHANGE`, conventional `!:` marker, or a breaking label.
- **Minor**: anything that looks like a feature or enhancement.
- **Patch**: everything else after ignore rules are applied.

Changelog sections: `Added` for features, `Fixed` for fixes/security, `Changed` for breaking and everything else.

## Ignore rules

Put ignore rules in the target repo's `changelog.yaml`:

```yaml
release_agent:
  ignore_commits:
    - author: "^pre-commit-ci\\[bot\\]$"
    - author: "^nextcloud-bot$"
    - author: "^dependabot\\[bot\\]$"
```

Rules are regexes. Omit a key to match anything.

## Releasing this CLI

It guides others to treasures it cannot possess.
Releases are manual for now.
