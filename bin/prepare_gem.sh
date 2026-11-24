#!/bin/bash
# Prepares a scratch workspace to type a gem: the packaged source, the
# upstream repository at the release tag (for its tests), and a Gemfile
# that loads the gem from that checkout plus its development dependencies,
# rbs and lumitrace. Nothing here runs the gem's code.
#
# Usage: prepare_gem.sh <gem> [version] [workdir]
#   version defaults to the latest release; workdir to ./rbs-work/<gem>
# Result:
#   <workdir>/pkg/          unpacked .gem (what users install)
#   <workdir>/repo/         upstream repo at the matching tag (if found)
#   <workdir>/env/Gemfile   BUNDLE_GEMFILE for running the repo's tests
#   <workdir>/gemhome/      GEM_HOME for this gem
# Then: cd <workdir>/env && GEM_HOME=../gemhome bundle install
set -euo pipefail
gem=$1; ver=${2:-}; W=${3:-$PWD/rbs-work/$gem}
mkdir -p "$W"/{pkg,gemhome}; W=$(cd "$W" && pwd)
if [ -z "$ver" ]; then
  ver=$(ruby -rjson -rnet/http -e 'puts JSON.parse(Net::HTTP.get(URI("https://rubygems.org/api/v1/gems/#{ARGV[0]}.json")))["version"]' "$gem")
fi
echo "gem: $gem $ver"
( cd "$W" && gem fetch "$gem" -v "$ver" >/dev/null && tar -xOf "$gem-$ver.gem" data.tar.gz | tar -xz -C pkg )
src=$(ruby -rjson -rnet/http -e '
  i = JSON.parse(Net::HTTP.get(URI("https://rubygems.org/api/v1/gems/#{ARGV[0]}.json")))
  u = [i["source_code_uri"], i["homepage_uri"]].compact.find { |x| x =~ %r{github\.com|gitlab\.com} }
  puts u.to_s.sub(%r{/(tree|blob)/.*}, "").sub(/\.git\z/, "").sub(%r{\Ahttp://}, "https://")' "$gem")
if [ -n "$src" ] && [ ! -d "$W/repo" ]; then
  tag=$(git ls-remote --tags "$src" 2>/dev/null | awk '{print $2}' | sed 's|refs/tags/||; s|\^{}||' | sort -u |
        grep -E "^(v|release-|releases/v|$gem-|${gem}_|)$ver$" | head -1 || true)
  if [ -n "$tag" ]; then
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" "$src" "$W/repo" && echo "repo: $src @ $tag"
  else
    echo "repo: $src (no tag for $ver; clone it yourself and pick the commit)" >&2
  fi
else
  echo "repo: not found in gem metadata; look up the source by hand" >&2
fi
if [ -d "$W/repo" ]; then
  mkdir -p "$W/env"
  gemspec=$(ls "$W/repo"/*.gemspec 2>/dev/null | head -1 || true)
  {
    echo 'source "https://rubygems.org"'
    if [ -n "$gemspec" ]; then
      echo "gemspec path: \"$W/repo\", name: \"$gem\", development_group: :development"
    else
      echo "gem \"$gem\", path: \"$W/repo\""
    fi
    [ -f "$W/repo/Gemfile" ] && echo "# The repo's own Gemfile, for reference: $W/repo/Gemfile"
    echo 'gem "rbs"'
    echo 'gem "lumitrace"'
  } > "$W/env/Gemfile"
  echo "env: $W/env/Gemfile (add test gems from the repo's Gemfile if bundle exec fails)"
fi
echo "workdir: $W"
