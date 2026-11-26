# gem_rbs_collection-tools

Tools for adding and verifying RBS signatures in
[ruby/gem_rbs_collection](https://github.com/ruby/gem_rbs_collection).

`bin/test` in gem_rbs_collection checks that signatures are consistent and
that `_test/test.rb` type-checks. These tools check that the signatures match
what the gem actually does. `gem-types` runs several type tools against a gem
(three of them while the gem's own test suite runs), compares what they
found method by method, writes a draft RBS from the best evidence, and then
verifies signatures with RBS runtime type checking.

## Setup

```
git clone https://github.com/pvcresin/gem_rbs_collection-tools
cd gem_rbs_collection-tools
bundle install
bundle exec ruby -Ilib test/gem_types_test.rb   # optional self-test
```

Ruby 3.3+. Network access to rubygems.org, bestgems.org and the gem's
source host.

## Commands

```
exe/gem-types pick     <gem_rbs_collection dir> [--top 500] [--limit 30] [--min-months N]
exe/gem-types prepare  <gem> [version] [workdir]
exe/gem-types run      <gem> [gem...] [--base DIR] [--jobs N] [--worktrees <gem_rbs_collection> [--ref REF]]
exe/gem-types collect  --workdir W --ns Foo --test-cmd "..." [--sources a,b] [--jobs N] [--require foo] [--lib lib] [--tests test,spec]
exe/gem-types draft    --workdir W [--existing path/to/foo.rbs]
exe/gem-types exists   --workdir W --sig path/to/foo.rbs
exe/gem-types steep    --workdir W --sig dir_or_file [--library json,uri]
exe/gem-types verify   --workdir W --sig path/to/foo.rbs
exe/gem-types update   --workdir W --sig gems/foo/1.2 [--from 1.2.0]
exe/gem-types pr-text  --workdir W --sig path/to/foo.rbs
exe/gem-types live     --workdir W --sig path/to/foo.rbs [--test-cmd "..."]
exe/gem-types check    [-s sigdir] [-t targets] [-o prefix] [-c calls] [-d rspec|minitest] -- <command>
exe/gem-types coverage <file.rbs> <calls file>
```

| Command | What it does |
|---|---|
| `pick` | Ranks gems to type next: top N by downloads, not yet in the collection (or without reviewers), oldest latest release. Skips gems that already have types (any `.rbs` in the package, or bundled with rbs) and gems with an open PR. |
| `prepare` | Unpacks the gem, clones upstream at the release tag, writes a Gemfile for its tests (package dependencies + the repo's Gemfile + rbs, rbs-trace, lumitrace) and guesses the test command. |
| `run` | `prepare` → bundle install → plain test run → namespace detection → `collect` → `draft` for several gems in parallel; skips a gem that fails a step, with the reason, and writes `run-summary.md`. Retries RSpec 2 specs with a compatibility shim and a failed install without the gems it names; with `--worktrees`, makes an `add-<gem>` worktree per gem and writes `workflow-args.json` for the `gem-rbs-author` workflow. |
| `collect` | Runs the evidence sources (below) and keeps their raw output in `W/evidence/`. |
| `draft` | Merges the evidence into `W/draft.rbs` and `W/report.md`: `self` returns, generic block pass-through, block argument types, DSL `[self: instance]`, attrs/Struct members; private and `@api private` methods left out. |
| `exists` | Loads the gem and checks that every declared method, class kind and superclass exists. |
| `steep` | Type-checks the gem's own code against the signatures; lists where they disagree. |
| `verify` | `exists` + `steep` + the gem's test suite with and without runtime type checking, declared methods the suite never called, declared types wider than anything the suite saw; prints a Verification section for the PR. |
| `pr-text` | Drafts the commit message / PR body: covered classes and methods, public methods left out, and the numbers saved by `verify` and `live`. |
| `live` | Reruns a command with every declared return type made `bot` and lists declarations that never failed: the ones the runtime checks did not really cover. |
| `update` | For an existing RBS and a new gem version: source changes since `--from`, declared methods that are gone, public methods not declared (with suggestions), Steep, test-suite type errors. |
| `check` | Runs any command under `rbs/test/setup`; `-o` records type errors instead of raising, `-c` records calls. |
| `coverage` | Lists methods declared in an RBS file that a run never called. |

## Evidence sources

| Source | Kind | Tool |
|---|---|---|
| `tracepoint` | runtime (test suite) | our TracePoint hook: types per call shape, and which shapes raised |
| `rbs_trace` | runtime (test suite; by default only when tracepoint recorded nothing) | [rbs-trace](https://github.com/sinsoku/rbs-trace) |
| `lumitrace` | runtime (test suite) | [Lumitrace](https://github.com/ko1/lumitrace), mapped to parameters and return expressions with Prism |
| `typeprof` | static (lib + tests) | [TypeProf](https://github.com/ruby/typeprof) |
| `tyda` | static (lib + tests) | [tyda](https://rubygems.org/gems/tyda) |
| `rigor` | static (lib, observing tests) | [Rigor](https://github.com/rigortype/rigor) `sig-gen` (needs Ruby 4.0, optional) |
| `yard` | documented contract | YARD docs via [Sord](https://github.com/AaronC81/sord) |
| `prototype` | structure | `rbs prototype runtime` |

Static sources run in parallel with the test runs. The report flags methods
where sources disagree, where calls only raised
(negative tests, which the RBS should reject), and methods with no runtime
evidence. See [docs/evidence.md](docs/evidence.md).

## Example

```
W=~/rbs-work/netrc
exe/gem-types prepare netrc "" $W
(cd $W/env && GEM_HOME=$W/gemhome GEM_PATH=$W/gemhome BUNDLE_GEMFILE=$W/env/Gemfile bundle install)
exe/gem-types collect --workdir $W --ns Netrc \
  --test-cmd 'for t in test/test_*.rb; do bundle exec ruby -Ilib -Itest $t; done'
exe/gem-types draft --workdir $W
less $W/report.md $W/draft.rbs
```

## Guides

- [docs/evidence.md](docs/evidence.md): the sources, the report, and turning a draft into signatures
- [docs/verification.md](docs/verification.md): runtime verification and telling real type errors from negative tests, test doubles and tool artifacts

## Policy notes

- A call that only ever raises in the gem's tests is the gem rejecting bad
  input; leave it out of the RBS so the type checker rejects it too. Do not
  add `-> bot` overloads for error cases.
- New gems are added without `_reviewers.yaml` (it is optional).
- Never execute code from `gems/` in gem_rbs_collection; anyone can open a
  pull request there. These tools only read RBS from it. The gems being typed
  and their test suites do run, in a separate workdir.

## Claude Code

Saved workflows in `.claude/workflows/`: `gem-rbs-author` (one agent per
gem writes and verifies the RBS, then an independent reviewer tries to
falsify it) and `gem-rbs-review` (the review alone, for existing RBS).

`.claude/skills/gem-rbs-collection/` is a skill that follows this workflow.
Include this repository in the session (or copy the skill into
`~/.claude/skills/`) to use it.
