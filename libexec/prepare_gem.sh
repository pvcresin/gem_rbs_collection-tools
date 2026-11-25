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
  ver=$(ruby -Eutf-8 -rjson -rnet/http -e 'puts JSON.parse(Net::HTTP.get(URI("https://rubygems.org/api/v1/gems/#{ARGV[0]}.json")))["version"]' "$gem")
fi
echo "gem: $gem $ver"
( cd "$W" && gem fetch "$gem" -v "$ver" >/dev/null && tar -xOf "$gem-$ver.gem" data.tar.gz | tar -xz -C pkg )
src=$(ruby -Eutf-8 -rjson -rnet/http -e '
  i = JSON.parse(Net::HTTP.get(URI("https://rubygems.org/api/v1/gems/#{ARGV[0]}.json")))
  meta = i["metadata"] || {}
  u = [i["source_code_uri"], i["homepage_uri"], i["bug_tracker_uri"], i["changelog_uri"],
       meta["source_code_uri"], meta["homepage_uri"], meta["bug_tracker_uri"], meta["changelog_uri"],
       i["documentation_uri"], i["wiki_uri"]].compact.find { |x| x =~ %r{github\.com/[^/]+/[^/]+|gitlab\.com/[^/]+/[^/]+} }
  u &&= u[%r{\Ahttps?://(?:github|gitlab)\.com/[^/]+/[^/#?]+}]
  puts u.to_s.sub(%r{/(tree|blob)/.*}, "").sub(/\.git\z/, "").sub(%r{\Ahttp://}, "https://")' "$gem")
if [ -d "$W/repo" ]; then
  echo "repo: $W/repo (already there)"
elif [ -n "$src" ]; then
  tag=$(git ls-remote --tags "$src" 2>/dev/null | awk '{print $2}' | sed 's|refs/tags/||; s|\^{}||' | sort -u |
        grep -E "^(v|release-|releases/v|$gem-|${gem}_|)$ver$" | head -1 || true)
  if [ -n "$tag" ]; then
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" "$src" "$W/repo" && echo "repo: $src @ $tag"
  else
    echo "repo: $src (no tag for $ver; clone it yourself and pick the commit)" >&2
  fi
else
  echo "repo: not found in gem metadata; clone the source at the release tag into $W/repo and rerun prepare" >&2
fi
if [ -d "$W/repo" ]; then
  mkdir -p "$W/env"
  here=$(cd "$(dirname "$0")" && pwd)
  ruby "$here/env_gemfile.rb" "$W/$gem-$ver.gem" "$W/repo" > "$W/env/Gemfile"
  echo "env: $W/env/Gemfile (from the package's dependencies and the repo's Gemfile)"
  cmd=$(ruby "$here/detect_test_cmd.rb" "$W/repo" "$W/env/Gemfile")
  if [ -n "$cmd" ]; then
    printf '%s\n' "$cmd" > "$W/test_cmd"
    echo "test command (guess, saved to $W/test_cmd; collect uses it unless --test-cmd is given): $cmd"
  else
    echo "test command: could not guess; pass --test-cmd to collect" >&2
  fi
fi
echo "workdir: $W"
