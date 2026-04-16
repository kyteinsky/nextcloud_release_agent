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

- Target repo needs `appinfo/info.xml` and a `changelog.yaml` (see [Adding changelog.yaml to an existing project](#adding-changelogy-to-an-existing-project) and `example/changelog.yaml`)
- The agent auto-detects `CHANGELOG.md`, `changelog.md`, or `changelog.generated.md` as the rendered output whichever already exists is updated in-place
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

Create release PR only
```bash
nextcloud-release-agent prepare
```

Create release branch with changes locally, no push
```bash
nextcloud-release-agent prepare --no-push
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

Prepare + publish in one shot
```bash
nextcloud-release-agent run --monitor
```

Normalize `changelog.yaml` and re-render the markdown changelog, should be done at the start
```bash
nextcloud-release-agent format
```

## How it works

**`format`**

Normalizes `changelog.yaml` in-place (indentation, key ordering, section ordering: Added -> Changed -> Fixed) and re-renders the markdown changelog so both files are in sync. Useful after manually editing `changelog.yaml` or when adding it to an existing project.

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

**`run`**

Runs `prepare` then `publish` in one shot. Use this for the happy path.

**`monitor`**

Watches GitHub Actions for the latest version or a specific version.

## Semver

Version is derived from commit and PR metadata:

- **Major**: `BREAKING CHANGE`, conventional `!:` marker, or a breaking label.
- **Minor**: anything that looks like a feature or enhancement.
- **Patch**: everything else after ignore rules are applied.

Changelog sections: `Added` for features, `Fixed` for fixes/security, `Changed` for breaking and everything else.

## Adding changelog.yaml to an existing project

Add a `changelog.yaml` alongside your existing changelog markdown file. The agent will keep updating it in-place. `CHANGELOG.md`, `changelog.md`, and `changelog.generated.md` are all detected automatically, no renaming needed.

The `changelog.yaml` becomes the source of truth going forward. Populate it with your release history from the existing markdown so the agent has context for semver bumping and duplicate detection.

### Minimal changelog.yaml structure

```yaml
repository_link: https://github.com/organisation/your-app
title: Change Log
description: All notable changes to this project will be documented in this file.
markdown_preamble: |-
  <!--
    - SPDX-FileCopyrightText: 2024 Nextcloud GmbH and Nextcloud contributors
    - SPDX-License-Identifier: AGPL-3.0-or-later
  -->
  # Change Log
  All notable changes to this project will be documented in this file.

  The format is based on [Keep a Changelog](http://keepachangelog.com/)
  and this project adheres to [Semantic Versioning](http://semver.org/).
release_agent:
  ignore_commits:
    - author: "^pre-commit-ci\\[bot\\]$"
    - author: "^Nextcloud-bot$"
    - email: "bot@nextcloud.com"
    - author: "^dependabot\\[bot\\]$"
entries:
  - version: "1.2.3"
    release_date: "2024-01-15"
    sections:
      - name: Added
        items:
          - text: some new feature
            issue_number: 42
            authors:
              - your-github-handle
      - name: Changed
        items:
          - text: something that changed
            issue_number: null
            authors: []
      - name: Fixed
        items:
          - text: some bug fix
            issue_number: 7
            authors:
              - contributor-handle
```

A snapshot of the file in the nextcloud/translate2 repo can be found in `example/changelog.yaml`.

### Steps

The `changelog.yaml` format is straightforward enough that you can populate it with AI in one shot. The existing changelog markdown is typically unstructured (inconsistent headings, mixed formats, missing issue numbers, author names instead of handles). Paste it into any capable model along with the schema from the example above and ask it to produce a valid `changelog.yaml`. Review the output for accuracy, then run `format` to normalise and verify the rendered markdown matches, or commit the newly rendered one.

If you prefer to do it manually:

1. Copy the `markdown_preamble` verbatim from the top of your existing changelog markdown (the copyright header and intro text).
2. For each release heading (`## x.y.z - YYYY-MM-DD`), add an entry under `entries:` with `version` and `release_date`.
3. Map each sub-heading to a section (`### Added` → `name: Added`, etc.).
4. For each bullet, set `text` (stripped of the leading `- `), `issue_number` (or `null`), and `authors` (GitHub handles, or `[]`).
5. Run `nextcloud-release-agent format --dry-run` to verify the rendered output matches your original markdown, then run it without `--dry-run` to normalize the YAML and regenerate the markdown file.

### Section ordering

The agent normalises sections into **Added -> Changed -> Fixed** order on every write. You don't need to keep them in that order in the YAML, they will be reordered automatically.

Any section name other than those three is preserved but appended after `Fixed`.

## Ignore rules

Add a `release_agent.ignore_commits` block to silence bots and automation from your changelog. Each rule is a set of regexes matched against the commit's author name, author email, and commit message. Omit a key to match anything (wildcard):

```yaml
release_agent:
  ignore_commits:
    - author: "^pre-commit-ci\\[bot\\]$"         # match only by author name
    - author: "^Nextcloud-bot$"
    - email: "bot@nextcloud.com"                 # match only by email
    - author: "^dependabot\\[bot\\]$"
    - message: "^chore: update translations"     # match only by commit message
    - author: "^renovate\\[bot\\]$"
      email: "bot@renovateapp\\.com"             # author AND email must both match
```

Rules are applied before PR enrichment, so ignored commits never appear in the changelog regardless of the PR they belong to.

## Releasing this CLI

It guides others to treasures it cannot possess.
Releases are manual for now.
