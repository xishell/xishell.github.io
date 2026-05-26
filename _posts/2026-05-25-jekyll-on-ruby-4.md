---
title: "Jekyll, Ruby 4, and a `tainted?` that isn't anymore"
date: 2026-05-25
description: How `github-pages` pinned me to a Liquid that bit-rotted, and why the fix was to drop the gem entirely and build with GitHub Actions.
tags: [jekyll, ruby, github-pages, blog]
---

I wanted a Jekyll blog under this site. Followed the github-pages
recipe, ran `bundle install`, ran `bundle exec jekyll serve`. Got this:

```
/opt/homebrew/lib/ruby/gems/4.0.0/gems/jekyll-3.9.0/lib/jekyll.rb:28:
  warning: csv used to be loaded from the standard library, but is
  not part of the default gems since Ruby 3.4.0.
cannot load such file -- csv (LoadError)
```

Add `gem "csv"` to the Gemfile, re-bundle, run again:

```
Liquid Exception: undefined method 'tainted?' for an instance of
  String in /_layouts/post.html
```

Liquid 4.0.3 calling `obj.tainted?` on a string. Ruby 4 removed
`String#tainted?` (deprecated 2.7, removed 3.2). The Liquid version
pinned by the `github-pages` gem was from 2022 and never picked up
the fix.

The recipe says "just use github-pages" and there's no version knob.
The gem locks Jekyll 3.9, Liquid 4.0.3, and a stack of plugins to
whatever GitHub's hosted builder runs. If your local Ruby is newer
than that stack, you get bit-rot like this.

## What "github-pages" actually is

It's not Jekyll. It's a gem that vendors a specific snapshot of Jekyll
+ plugins, so the local build matches what GitHub's hosted builder
will produce. The whole point is reproducibility against an old
server.

The cost: you can't upgrade Jekyll independently. When Ruby moves
forward and the pinned Liquid breaks, you're stuck.

## The fix is to stop using the gem

GitHub Pages can deploy from a GitHub Actions workflow instead of
its built-in builder. That lets you pick your own Jekyll version.

`.github/workflows/pages.yml`:

```yaml
name: Build and deploy Jekyll

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.3"
          bundler-cache: true
      - uses: actions/configure-pages@v5
      - run: bundle exec jekyll build
        env: { JEKYLL_ENV: production }
      - uses: actions/upload-pages-artifact@v3
        with: { path: _site }

  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - id: deployment
        uses: actions/deploy-pages@v4
```

Then a Gemfile that drops the gem and asks for Jekyll directly:

```ruby
source "https://rubygems.org"

gem "jekyll", "~> 4.3"
gem "kramdown-parser-gfm"

group :jekyll_plugins do
  gem "jekyll-feed"
  gem "jekyll-seo-tag"
  gem "jekyll-sitemap"
end

# Ruby 3.4+ moved these out of default gems
gem "csv"
gem "base64"
gem "bigdecimal"
gem "logger"
gem "ostruct"
gem "webrick"
```

One repo setting to flip: Settings → Pages → Source: **GitHub
Actions** (not "Deploy from branch"). Otherwise the hosted builder
ignores the workflow and rebuilds with the old Jekyll.

The build runs in CI in 30 seconds now. Local preview still uses my
homebrew Ruby 4, and Jekyll 4 doesn't mind it because Liquid 5 long
since gave up on `tainted?`. The github-pages gem exists to keep the
local build in sync with GitHub's hosted builder — the moment you've
taken over the builder, it stops earning its keep.
