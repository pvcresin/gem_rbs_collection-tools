# gem_rbs_collection-tools

Tools for adding and verifying RBS signatures in
[ruby/gem_rbs_collection](https://github.com/ruby/gem_rbs_collection).

`bin/test` in gem_rbs_collection checks that signatures are consistent and
that `_test/test.rb` type-checks. These tools check that the signatures match
what the gem actually does: they collect the types that flow through a gem
while its own test suite runs, build a draft RBS from that evidence, and run
the gem (and its test suite) under RBS runtime type checking.

## Requirements

- Ruby 3.3+ and the `rbs` gem (4.x)
- Network access to rubygems.org, bestgems.org and the gem's source host
- Optional: [`tyda`](https://rubygems.org/gems/tyda) (static inference),
  [`lumitrace`](https://github.com/ko1/lumitrace) (expression-level tracing)

## Workflow

```
# 1. Pick gems: top downloads, not in the collection yet, not released recently
ruby $TOOLS/bin/pick_gems.rb ~/src/gem_rbs_collection --top 500 --min-months 24 --limit 30

# 2. Prepare: packaged gem, upstream repo at the release tag, a Gemfile for its tests
$TOOLS/bin/prepare_gem.sh netrc "" ~/rbs-work/netrc
W=~/rbs-work/netrc
(cd $W/env && GEM_HOME=$W/gemhome bundle install)

# 3. Observe the types the test suite exercises
cd $W/repo
export BUNDLE_GEMFILE=$W/env/Gemfile GEM_HOME=$W/gemhome GEM_PATH=$W/gemhome
OBSERVE_NS="Netrc,Netrc::*" OBSERVE_OUT=$W/obs.types \
  RUBYOPT="-r$TOOLS/bin/observe_types.rb" bundle exec ruby -Ilib -Itest test/test_netrc.rb

# 4. Draft RBS from the observations (+ static inference)
tyda lib test > $W/tyda.rbs
ruby $TOOLS/bin/draft_rbs.rb --observed $W/obs.types.json --tyda $W/tyda.rbs --ns Netrc

# 5. Verify: run code under RBS runtime type checking
$TOOLS/bin/rbs_check.sh -s ~/src/gem_rbs_collection/gems/netrc/0.11 -t "Netrc,Netrc::*" \
  -c $W/calls.tsv -- ruby my_calls.rb
ruby $TOOLS/bin/coverage_report.rb ~/src/gem_rbs_collection/gems/netrc/0.11/netrc.rbs $W/calls.tsv
$TOOLS/bin/rbs_check.sh -s ~/src/gem_rbs_collection/gems/netrc/0.11 -t "Netrc,Netrc::*" \
  -d minitest -o $W/suite -- bundle exec ruby -Ilib -Itest test/test_netrc.rb
```

`$TOOLS` is the path to this repository.

## Tools

| Script | What it does |
|---|---|
| `bin/pick_gems.rb` | Ranks candidate gems: top N by downloads, new to the collection (or without reviewers), oldest latest release. Skips gems that ship `sig/` or are bundled with rbs. |
| `bin/prepare_gem.sh` | Unpacks the gem, clones upstream at the matching tag, writes a Gemfile with its development dependencies, rbs and lumitrace. |
| `bin/observe_types.rb` | Loaded with `-r`. Records argument, block and return types per public method and per call shape, including which shapes raised. Writes text and JSON. |
| `bin/draft_rbs.rb` | Merges observations (and optionally tyda output and existing RBS) into a draft RBS with a source comment per method. Calls that only raised are left out. |
| `bin/rbs_check.sh` | Runs any command with `rbs/test/setup`. `-o` records type errors (with counts and the first test frame) instead of raising; `-c` records calls for coverage. |
| `bin/coverage_report.rb` | Lists methods declared in an RBS file that a run never called. |
| `bin/log_errors.rb`, `bin/trace_calls.rb` | Loaded by `rbs_check.sh`. |

## Guides

- [docs/evidence.md](docs/evidence.md): gathering type evidence and turning it into signatures
- [docs/verification.md](docs/verification.md): runtime verification and how to tell real type errors from negative tests, test doubles and tool artifacts

## Policy notes

- A call that only ever raises in the gem's tests is the gem rejecting bad
  input; leave it out of the RBS so the type checker rejects it too. Do not
  add `-> bot` overloads for error cases.
- New gems are added without `_reviewers.yaml` (it is optional).
- Never execute code from `gems/` in gem_rbs_collection; anyone can open a
  pull request there. These tools only read RBS from it.

## Claude Code

`.claude/skills/gem-rbs-collection/` is a skill that follows this workflow.
Include this repository in the session (or copy the skill into
`~/.claude/skills/`) to use it.
