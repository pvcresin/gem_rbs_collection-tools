# Gathering type evidence

`gem-types collect` runs several tools against a gem and `gem-types draft`
merges what they found. Each tool sees the gem differently, so where they
agree the type is probably right, and where they disagree is where to look.

| Source | How | What it is good for | Weak spots |
|---|---|---|---|
| `tracepoint` | Our TracePoint hook while the test suite runs | Real argument/block/return types per **call shape**, and which shapes raised (negative tests) | Only what the tests call; element types sampled from 5 items |
| `rbs_trace` | [rbs-trace](https://github.com/sinsoku/rbs-trace) while the tests run | Independent runtime check of the same calls, generic Array/Hash/Range | No blocks; writes `void` when the caller ignored the value; one overload per shape |
| `lumitrace` | [Lumitrace](https://github.com/ko1/lumitrace) "types" mode while the tests run | Types of every expression; here mapped to parameters and to the method's return expressions (if/case branches included) | No element types (`Array`); explicit `return` inside loops is missed |
| `typeprof` | TypeProf over `lib` + `test` | Static inference including call sites in the tests; tuples and literal types | Often too precise (tuples) or untyped; slow on big code bases |
| `tyda` | [tyda](https://rubygems.org/gems/tyda) over `lib` + `test` | Fast static inference, call-site types from the tests, class structure | Many `untyped` |
| `rigor` | [Rigor](https://github.com/rigortype/rigor) `sig-gen --params=observed` over `lib`, observing `test` | Independent inference engine; parameter types from call sites in the tests | Needs Ruby 4.0; young project (0.4.x); skips methods it cannot type |
| `yard` | YARD docs turned into RBS by [Sord](https://github.com/AaronC81/sord) | The **documented contract** (`@param`/`@return`), which tests may not exercise | Only as good as the docs; stale docs happen |
| `prototype` | `rbs prototype runtime` on the loaded gem | The real method list, parameter names and kinds, class/module structure | No types |

## Workflow

```
T=$TOOLS/exe/gem-types       # $TOOLS: this repository, `bundle install` done
W=$SCRATCH/rbs-work/netrc

$T prepare netrc "" $W
(cd $W/env && GEM_HOME=$W/gemhome GEM_PATH=$W/gemhome BUNDLE_GEMFILE=$W/env/Gemfile bundle install)

# Make the tests pass without tooling first (add test gems to $W/env/Gemfile)
(cd $W/repo && BUNDLE_GEMFILE=$W/env/Gemfile GEM_HOME=$W/gemhome GEM_PATH=$W/gemhome \
   bash -c 'for t in test/test_*.rb; do bundle exec ruby -Ilib -Itest $t; done')

$T collect --workdir $W --ns Netrc      # uses $W/test_cmd from prepare, or --test-cmd '...'
$T draft --workdir $W [--existing <gem_rbs_collection>/gems/netrc/0.11/netrc.rbs]
```

- `prepare` writes `$W/env/Gemfile` from the **packaged gem's** dependency
  metadata plus the gems in the repo's Gemfile (linters and debuggers
  dropped), not from the repo's gemspec: Bundler evaluates a gemspec at
  startup, and many gemspecs `require` the library, which loads it before any
  tracing hook (Lumitrace then sees nothing). The tests load the library from
  `repo/lib` via `-Ilib`. If a gem from the repo's Gemfile does not
  install, remove its line; if a test helper still misses something, add it.
- `prepare` also guesses the test command (rspec, `rake test`, or a loop
  over test files) and saves it to `$W/test_cmd`.
- `--test-cmd` runs in `repo/` with that environment
  (`BUNDLE_DISABLE_EXEC_LOAD=true` is set so `bundle exec rspec` starts a
  real process the hooks can attach to). Every Ruby process it
  starts is traced and writes its own output, so loops over test files work.
  Use the command the repo uses (`bundle exec rspec`, `bundle exec rake
  test`, or a loop over files).
- `collect --sources tracepoint,lumitrace` reruns only some sources; settings
  are saved in `$W/gem-types.json`.
- Options: `--require` (what to require for `prototype`, default from the
  namespace), `--lib` (default `lib`), `--tests` (default `test,spec`),
  `--jobs N` (test runs in parallel; default 1 because test suites may share
  files or ports). Static sources always run in parallel with the test runs.
- Rigor needs Ruby 4.0. gem-types uses `RIGOR_RUBY`, or else the newest
  rbenv-installed Ruby 4.x, with rigortype in `RIGOR_GEM_HOME` (default
  `~/.gem/rigor`); otherwise the source is skipped. Setup:
  `rbenv install -s 4.0.6 && GEM_HOME=~/.gem/rigor $(rbenv root)/versions/4.0.6/bin/gem install rigortype`.

## Output

`$W/draft.rbs`: one signature per method, taken from the best available
source (runtime first: tracepoint, rbs_trace, lumitrace, then typeprof,
rigor, tyda, yard, prototype), with a comment saying where it came from:

```
  # observed 19 calls (raises Netrc::Error) | from tracepoint | also: rbs_trace, lumitrace, typeprof, tyda, prototype
  def self.read: (?String path) -> Netrc
```

`$W/report.md`: per source counts, a "Needs attention" list, then every
method with each source's signature and tracepoint's call shapes:

```
### `Timecop.scale`
- tracepoint (11 calls, raises TypeError): `(*(Integer | Time)? args) ?{ (?) -> untyped } -> Time | bool`
- rbs_trace: `(*nil) -> Time | (*Integer) -> bool | ... | (*String) -> nil`
- typeprof: `(*(Integer | String | Time)? args) -> Time`
- call shapes:
  (Integer) -> Time
  (Integer) {} -> bool
  (String) -> raise TypeError      <- negative test: leave out of the RBS
  (nil) -> Time                    <- a normal use: accept nil
```

Flags in "Needs attention":

- **raises in tests**: look at the shapes. A shape that only raises is
  usually a negative test. Do not accept it in the RBS (and do not add a
  `-> bot` overload for it).
- **runtime sources disagree**: compare the shapes; one tool may be missing
  something (e.g. tracepoint once recorded an Array subclass as `Array`;
  rbs-trace and Lumitrace showed `Netrc::TokenArray`).
- **static inference differs from runtime**: static tools saw a call or a
  path the tests did not run, or are just imprecise. Read the source.
- **YARD docs differ from runtime**: the docs promise something the tests
  do not show (or the docs are stale). Check which is the contract.
- **no runtime evidence**: the tests never call it. Type it from the source
  and make sure the verification script calls it.
- **not in existing RBS / in existing RBS but not observed** (with
  `--existing`): gaps in either direction.

## Turning the draft into signatures

The draft is evidence, not the answer:

- Read the source of every method; name parameters; drop internals
  (`@private`, helpers that happen to be public).
- Replace observed concrete types with the intended ones (a test passing
  `Array[String]` does not mean other element types are rejected), and turn
  block-return unions into a type parameter (`[T] () { () -> T } -> T`).
- Prefer the documented contract when the docs promise more than the tests
  exercise.

## Single tools by hand

- TracePoint hook: `RUBYOPT=-r$TOOLS/lib/gem_types/hooks/observe.rb OBSERVE_NS="Foo,Foo::*" OBSERVE_OUT=/tmp/foo.types <test command>`
- Lumitrace on a range, with an HTML view: `LUMITRACE_ENABLE=1 LUMITRACE_ROOT=$PWD/lib LUMITRACE_RANGE="lib/foo.rb:10-40" LUMITRACE_HTML=/tmp/foo.html <test command>`
- `tyda why` / `tyda trace` show where tyda's inferred type came from.

## Choosing tools

Sources were picked for being maintained and for adding a different view;
a buggy source only adds noise to the comparison.

- Kept: TypeProf, rbs (prototype), Steep, YARD, Sord, Lumitrace, tyda
  (all released within the last year), Rigor (very active, but young).
- rbs-trace: last release 2025-09. Kept as a second runtime opinion; ranked
  below our TracePoint hook, which records call shapes and exceptions.
- Not used: Tapioca's gem RBI generation. It reflects on the loaded gem like
  `rbs prototype runtime` and adds few types for untyped gems, and it needs
  a Sorbet project. Method existence, mixins and superclasses are covered by
  `prototype` and `gem-types exists`.
