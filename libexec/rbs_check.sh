#!/bin/bash
# Run a Ruby command with RBS runtime type checking (rbs/test/setup).
#
# Usage: rbs_check.sh [options] -- <command...>
#   -s DIR     signature dir (e.g. gems/vcr/6.4); repeatable
#   -t LIST    RBS_TEST_TARGET, e.g. "VCR,VCR::*"
#   -l LIB     stdlib signature to load (date, stringio, ...); repeatable
#   -k LIST    RBS_TEST_SKIP, absolute names: "::VCR::Request::Typed"
#   -d SUITE   test double suite: rspec | minitest
#   -o PREFIX  output prefix. Enables "log mode": type errors are recorded
#              to PREFIX.errors.tsv (with counts) instead of raised, and
#              PREFIX.checked.tsv counts every checked call, PREFIX.errors.jsonl
#              has one machine-readable record per distinct error.
#   -c FILE    also record every method call (for coverage_report.rb)
#   -h         show this help
#
# Libraries listed in a manifest.yaml next to the signatures (the
# gem_rbs_collection format) are loaded automatically.
#
# Without -o, the first type error raises RBS::Test::Tester::TypeError.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SIGS=(); LIBS=(); TARGETS=""; SKIP=""; DBL=""; OUT=""; CALLS=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s) SIGS+=("$2"); shift 2;; -l) LIBS+=("$2"); shift 2;;
    -t) TARGETS=$2; shift 2;; -k) SKIP=$2; shift 2;; -d) DBL=$2; shift 2;;
    -o) OUT=$2; shift 2;; -c) CALLS=$2; shift 2;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;;
    --) shift; break;; *) echo "unknown option $1" >&2; exit 2;;
  esac
done
[ -n "$TARGETS" ] || { echo "-t is required" >&2; exit 2; }
opt=""; for s in "${SIGS[@]}"; do opt="$opt -I $(cd "$s" && pwd)"; done
for s in "${SIGS[@]}"; do
  if [ -f "$s/manifest.yaml" ]; then
    while read -r l; do LIBS+=("$l"); done < <(ruby -ryaml -e 'puts (YAML.load_file(ARGV[0])["dependencies"] || []).map { _1["name"] }' "$s/manifest.yaml")
  fi
done
for l in "${LIBS[@]}"; do opt="$opt -r $l"; done
# rbs from the default gem environment, even when GEM_HOME points elsewhere
RBSLIB=${RBS_LIB:-$(env -u GEM_HOME -u GEM_PATH -u BUNDLE_GEMFILE ruby -e 'print Gem::Specification.find_by_name("rbs").full_gem_path')/lib}
export RBS_TEST_TARGET="$TARGETS" RBS_TEST_OPT="$opt" RBS_TEST_LOGLEVEL=error
[ -n "$SKIP" ] && export RBS_TEST_SKIP="$SKIP"
[ -n "$DBL" ] && export RBS_TEST_DOUBLE_SUITE="$DBL"
ro="-I$RBSLIB -r$HERE/rbs_preload.rb -rrbs/test/setup -r$HERE/rbs_hook_fix.rb -r$HERE/skip_timing.rb"
if [ -n "$OUT" ]; then export RBS_ERR_OUT="$(realpath -m "$OUT")"; rm -f "$RBS_ERR_OUT.checked.tsv" "$RBS_ERR_OUT.errors.tsv" "$RBS_ERR_OUT.errors.jsonl"; ro="$ro -r$HERE/log_errors.rb"; fi
if [ -n "$CALLS" ]; then export TRACE_OUT="$(realpath -m "$CALLS")"; rm -f "$TRACE_OUT"; ro="$ro -r$HERE/trace_calls.rb"; fi
export RUBYOPT="$ro ${RUBYOPT:-}"
# `bundle exec <cmd>` normally loads <cmd> inside the bundle process, where
# RUBYOPT's -r files (rbs, which needs psych etc.) were already required
# before Bundler.setup, so a Gemfile pinning another version of a default
# gem fails ("already activated psych 5.1.2, but your Gemfile requires
# psych 3.1.0"). Exec instead: Bundler.setup then runs before RUBYOPT.
export BUNDLE_DISABLE_EXEC_LOAD=true
exec "$@"
