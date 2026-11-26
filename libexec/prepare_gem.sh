#!/bin/bash
# Prepares a scratch workspace to type a gem: the packaged source, the
# upstream repository at the release tag (for its tests), and a Gemfile
# that loads the gem from that checkout plus its development dependencies,
# rbs and lumitrace. Nothing here runs the gem's code.
#
# Usage: prepare_gem.sh <gem> [version] [workdir]
#   version defaults to the latest release; workdir to ./rbs-work/<gem>
# Result:
#   <workdir>/<gem>-<ver>.gem  the package (the pure-Ruby one when there are platform builds)
#   <workdir>/pkg/          unpacked .gem (what users install)
#   <workdir>/repo/         upstream repo at the matching tag (if found)
#   <workdir>/repo_dir      the gem's root in repo/ (repo/<subdir> in a monorepo)
#   <workdir>/version       the prepared version (rerunning with another one starts over)
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

# A workdir prepared for another version starts over: the old checkout,
# package and test command would mix with the new ones.
prev=""
if [ -f "$W/version" ]; then
  prev=$(cat "$W/version")
else
  # Older workdirs have no version file: go by the package file names.
  for f in "$W/$gem"-*.gem; do
    [ -e "$f" ] || continue
    v=$(basename "$f" .gem); v=${v#"$gem"-}
    case "$v" in "$ver"|"$ver"-*) ;; *) prev=$v ;; esac
  done
fi
if [ -n "$prev" ] && [ "$prev" != "$ver" ]; then
  echo "workdir was prepared for $gem $prev: removing its repo/, pkg/, env/ and package"
  rm -rf "$W/repo" "$W/env" "$W/test_cmd" "$W/repo_dir"
fi
rm -rf "$W/pkg"; mkdir -p "$W/pkg"
for f in "$W/$gem"-*.gem; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in "$gem-$ver.gem") ;; *) rm -f "$f" ;; esac
done

# Platform builds (ffi, nokogiri, ...): take the pure-Ruby package, whose
# lib/ matches the repository; fall back to whatever `gem fetch` gives.
pkgfile="$W/$gem-$ver.gem"
if [ ! -f "$pkgfile" ]; then
  ( cd "$W" && { gem fetch "$gem" -v "$ver" --platform ruby >/dev/null 2>&1 && [ -f "$gem-$ver.gem" ]; } ||
               gem fetch "$gem" -v "$ver" >/dev/null )
  if [ ! -f "$pkgfile" ]; then
    pkgfile=$(ls -1 "$W/$gem-$ver"-*.gem 2>/dev/null | head -1 || true)
    [ -n "$pkgfile" ] || { echo "gem fetch $gem -v $ver: no package" >&2; exit 1; }
    echo "package: $(basename "$pkgfile") (no pure-Ruby package for $ver)"
  fi
fi
tar -xOf "$pkgfile" data.tar.gz | tar -xz -C "$W/pkg"
printf '%s\n' "$ver" > "$W/version"

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
    # A tag named like the version can belong to another project in a
    # monorepo (aws-sdk-ruby's v1.4.1 is aws-sdk 1.x, not aws-eventstream
    # 1.4.1): the checkout must contain this gem.
    if [ -d "$W/repo" ] && [ -z "$(cd "$W/repo" && git ls-files "$gem.gemspec" "*/$gem.gemspec" "lib/$gem.rb" "lib/${gem//-//}.rb" "*/lib/$gem.rb" "*/lib/${gem//-//}.rb" 2>/dev/null | head -1)" ]; then
      echo "repo: tag $tag does not contain $gem; looking for the version commit instead" >&2
      rm -rf "$W/repo"
      tag=""
    fi
  fi
  if [ -z "$tag" ]; then
    # No tag: take the default branch at the commit that set the version
    # (the oldest commit whose version file or gemspec diff has the version
    # as a quoted string, or a VERSION file with just the version).
    git clone -q --depth 500 "$src" "$W/repo" 2>/dev/null || true
    commit=""
    if [ -d "$W/repo/.git" ]; then
      vre=${ver//./\\.}
      cands=$(cd "$W/repo" && {
        git log --format=%H -G"[\"']$vre[\"']" -- '*version.rb' '*.gemspec' 2>/dev/null || true
        git log --format=%H -G"^$vre\$" -- VERSION '*/VERSION' 2>/dev/null || true
      })
      if [ -n "$cands" ]; then
        commit=$(cd "$W/repo" && git rev-list --topo-order --reverse HEAD | grep -Fx -f <(printf '%s\n' "$cands") | head -1 || true)
      fi
    fi
    if [ -n "$commit" ]; then
      (cd "$W/repo" && git -c advice.detachedHead=false checkout -q "$commit")
      echo "repo: $src @ $commit (no tag for $ver; the commit that set the version)"
    else
      rm -rf "$W/repo"
      echo "repo: $src (no tag or version commit for $ver; clone it yourself and pick the commit)" >&2
    fi
  fi
else
  echo "repo: not found in gem metadata; clone the source at the release tag into $W/repo and rerun prepare" >&2
fi
if [ -d "$W/repo" ]; then
  # Monorepos (sinatra/rack-protection, rspec, ...): the gem lives in the
  # directory holding <gem>.gemspec.
  root="$W/repo"
  if [ ! -f "$root/$gem.gemspec" ]; then
    sub=$(cd "$W/repo" && git ls-files "*/$gem.gemspec" 2>/dev/null | awk '{ print length($0) "\t" $0 }' | sort -n | head -1 | cut -f2- || true)
    if [ -n "$sub" ]; then
      root="$W/repo/$(dirname "$sub")"
      echo "repo: the gem is in $(dirname "$sub")/ of the repository"
    fi
  fi
  printf '%s\n' "$root" > "$W/repo_dir"
  # A saved config from an earlier run keeps pointing at the gem's root.
  if [ -f "$W/gem-types.json" ]; then
    ruby -rjson -e 'f, r = ARGV; c = JSON.parse(File.read(f)); c["repo"] == r or File.write(f, JSON.pretty_generate(c.merge("repo" => r)))' \
      "$W/gem-types.json" "$root"
  fi
  mkdir -p "$W/env"
  here=$(cd "$(dirname "$0")" && pwd)
  ruby "$here/env_gemfile.rb" "$pkgfile" "$root" > "$W/env/Gemfile"
  echo "env: $W/env/Gemfile (from the package's dependencies and the repo's Gemfile)"
  cmd=$(ruby "$here/detect_test_cmd.rb" "$root" "$W/env/Gemfile")
  if [ -n "$cmd" ]; then
    printf '%s\n' "$cmd" > "$W/test_cmd"
    echo "test command (guess, saved to $W/test_cmd; collect uses it unless --test-cmd is given): $cmd"
  else
    rm -f "$W/test_cmd"
    echo "test command: could not guess; pass --test-cmd to collect" >&2
  fi
fi
echo "workdir: $W"
