# Gemfile — local preview + dependency pinning for this Jekyll site.
#
# Production and CI build this site with GitHub Pages' own engine
# (actions/jekyll-build-pages in .github/workflows/build-check.yml). The
# `github-pages` gem pins Jekyll and every plugin to the exact versions that
# engine uses, so `bundle exec jekyll serve` renders locally what actually
# deploys — no local-vs-production drift. The active plugins (jekyll-seo-tag,
# jekyll-sitemap) belong to the GitHub Pages set and are switched on via the
# `plugins:` list in _config.yml.
#
# One-time setup on Windows (after installing Ruby+Devkit from rubyinstaller.org):
#   gem install bundler
#   bundle install
# Then, to preview (from the repo root):
#   bundle exec jekyll serve --livereload
#   -> open http://localhost:4000/  (research list at /research/)

source "https://rubygems.org"

gem "github-pages", group: :jekyll_plugins

# Ruby 3.x dropped webrick from the standard library; Jekyll's local server needs it.
gem "webrick", "~> 1.8"

# Windows and JRuby ship no timezone database — bundle one so date handling works.
platforms :mingw, :x64_mingw, :mswin, :jruby do
  gem "tzinfo", ">= 1", "< 3"
  gem "tzinfo-data"
end

# Optional: faster directory-watching for `jekyll serve` on Windows. Remove this
# line if it causes install trouble — it only affects live-reload speed.
gem "wdm", "~> 0.2", platforms: [:mingw, :x64_mingw, :mswin]
