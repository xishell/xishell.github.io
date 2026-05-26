---
title: "Why release-please went quiet on my first tag"
date: 2026-05-26
description: Three traps adopting release-please on a Python repo — bootstrap-sha, package-name, and the trigger that never fires. Each fix is a one-line config delete or a workflow restructure.
tags: [ci, github-actions, release-please]
---

Adopted release-please on a Python project to handle versioning and
the CHANGELOG. The action ran on every push to main, but no release
PR appeared. When the PR did appear, merging it didn't cut a tag.
When the tag finally cut, the downstream publish workflow refused to
run.

Three traps in a row. All silent — green checks, empty results. The
diffs that fixed each are small.

## Trap 1: bootstrap-sha that points at a recent commit

The first config tried to use `bootstrap-sha` to ignore pre-adoption
history:

```json
{
  "bootstrap-sha": "550fecc5e848d33dabfb0f680fe9c6d5e57d53c1",
  "packages": {
    ".": { "release-type": "python" }
  }
}
```

`bootstrap-sha` tells release-please: "for the initial release PR,
treat commits since this SHA as the release scope." Sensible if your
repo has years of history and you only want to release from now on.

The trap: if `bootstrap-sha` is set on *every* run rather than just
the bootstrap, release-please uses it as a hard floor forever. On
later runs, if your last tag is past the bootstrap-sha (which it is,
since you've now released), the bot sees no new commits worth
releasing and silently does nothing. No error, no warning. Just a
happy "ran successfully" green check and an empty Actions tab.

Fix: delete the line. release-please uses the last tag as the lower
bound after the initial release.

```diff
 {
-  "bootstrap-sha": "550fecc...",
   "packages": { ".": { "release-type": "python" } }
 }
```

Release PR appeared on the next push.

## Trap 2: package-name on a single-package repo

The release PR opened, but the branch was named
`release-please--branches--main--components--<name>--`, with the
trailing component segment. Merging produced no tag.

The config had:

```json
{
  "packages": {
    ".": {
      "release-type": "python",
      "package-name": "<name>",
      "include-component-in-tag": false
    }
  }
}
```

`package-name` is the package's published name. release-please uses
it as the *component* in branch names, tag templates, and changelog
headings — built for monorepos where multiple packages release
independently.

On a single-package repo, the component-in-branch convention doesn't
match the standalone tag scheme. `include-component-in-tag: false`
prevents the tag from getting the prefix, but the *branch* name still
carries the component, and release-please's reconciliation expects a
branch *without* the component when component-in-tag is off.

Result: the bot opened a PR, merged it, then couldn't find its own
release artifact to tag against. Silent again.

Fix: drop `package-name`. release-please uses the directory key
(`.`) as the implicit component with no suffix.

```diff
 "packages": {
   ".": {
     "release-type": "python",
-    "package-name": "<name>",
     "include-component-in-tag": false
   }
 }
```

The tag cut on the next merged release PR.

## Trap 3: GITHUB_TOKEN releases don't fire `release.published`

Tag cut, release object created on GitHub, downstream publish
workflow still didn't run.

The publish workflow was wired to GitHub's recommended trigger:

```yaml
on:
  release:
    types: [published]
```

This is a documented GitHub quirk: a workflow run authenticated with
`GITHUB_TOKEN` cannot trigger another workflow run. It's a
loop-prevention guard, and `release-please-action` uses
`GITHUB_TOKEN` by default. The release object lands, the
`release.published` event fires, but no workflow picks it up.

The official advice is "use a Personal Access Token instead." Works,
but introduces a PAT to rotate and a security boundary I'd rather
not maintain for one workflow.

The fix that doesn't need a PAT: chain the workflows explicitly via
`workflow_call` in the same job graph.

{% raw %}
```yaml
jobs:
  release-please:
    runs-on: ubuntu-latest
    outputs:
      release_created: ${{ steps.rp.outputs.release_created }}
      tag_name: ${{ steps.rp.outputs.tag_name }}
    steps:
      - uses: googleapis/release-please-action@v4
        id: rp

  publish:
    needs: release-please
    if: ${{ needs.release-please.outputs.release_created == 'true' }}
    uses: ./.github/workflows/publish-schemas.yml
    with:
      tag: ${{ needs.release-please.outputs.tag_name }}
    secrets: inherit
```
{% endraw %}

The downstream workflow becomes `workflow_call`-capable:

```yaml
on:
  workflow_call:
    inputs:
      tag:
        required: true
        type: string
```

Same file, same secrets, no PAT. release-please runs, publish runs as
its dependent in the same job graph, the cross-workflow trigger
restriction never applies because there isn't one to trigger.

All three failures were silent. The action exited green, the release
PR looked right, the tag appeared — and yet the next thing didn't
happen. The failure mode for an automation tool is rarely "throws";
it's "succeeds but doesn't do the thing."

Worth adding a five-second smoke check after each automation step:
did the artifact you expected actually land? For release-please,
that's "did the publish workflow run show up in the Actions tab for
the right tag?" For a tag cut, it's `git fetch && git tag --list`
locally. Both would have caught all three of these before the next
push pinned the wrong assumption.
