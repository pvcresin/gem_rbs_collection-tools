# Runtime verification

## Contents
1. Setup (scratch gem home)
2. Calling every declared method
3. Running the gem's own test suite
4. Triage: which type errors are real
5. Tool limits and workarounds

`$TOOLS` is the root of this repository; run `bundle install` there once.
All of them use the `rbs` gem's runtime checker (`rbs/test/setup`), which
wraps every method of the target classes and checks arguments, block and
return value against the RBS on each call. They were written for rbs 4.x.

## 1. Setup

Keep everything outside the repository:

```
W=<scratch>/rbs-verify; mkdir -p $W/{sig,gemhome,scripts,work,src}
git -C <repo> archive <branch> gems/<gem> | tar -x -C $W/sig   # RBS as data
GEM_HOME=$W/gemhome gem install --no-document <gem>:<version> <deps…>
```

Export the RBS from the branch with `git archive` rather than reading the
working tree, so you check exactly what is committed. Re-export after every
fix.

## 2. Call every declared method

Write `$W/scripts/<gem>.rb` that requires the gem and calls the API. Wrap
each step so one failure does not stop the rest:

```ruby
def t(label)
  yield
  puts "ok   #{label}"
rescue Exception => e          # TypeError from rbs/test is not a StandardError
  puts "EXC  #{label}: #{e.class}: #{e.message[0, 200]}"
end
```

Run it, recording calls for coverage:

```
cd $W/work && GEM_HOME=$W/gemhome GEM_PATH=$W/gemhome \
  $TOOLS/exe/gem-types check -s $W/sig/gems/<gem>/<ver> -t "Foo,Foo::*" \
    [-l date] -c $W/work/<gem>.calls -- ruby $W/scripts/<gem>.rb
GEM_HOME=$W/gemhome GEM_PATH=$W/gemhome:$(gem env gempath) \
  $TOOLS/exe/gem-types coverage $W/sig/gems/<gem>/<ver>/<gem>.rbs $W/work/<gem>.calls
```

- Without `-o`, a type error raises and the `t` wrapper prints it as `EXC`.
  Every `ok` line therefore means every hooked call inside it matched the RBS.
- If the RBS reopens core classes (e.g. aliases on `Time`), add them to `-t`.
- `coverage_report.rb` prints uncalled declarations; keep adding calls until
  it prints none. Use named classes in the script (anonymous classes cannot
  be matched to their ancestors).
- Exercise each overload and the optional/nil paths, not just one call per
  method: block and no-block, nil arguments, each union member.
- An `EXC` is not automatically an RBS bug: check your script first (wrong
  method name, invalid call the gem itself rejects). Run the same call
  without `rbs_check.sh` to see what the gem really does.

## 3. The gem's own test suite

```
git clone --depth 1 --branch <tag> https://github.com/<owner>/<repo> $W/src/<repo>
```

Install its test deps into the scratch GEM_HOME. If its test helper uses
`bundler/setup`, either `bundle install` its Gemfile (append
`gem "rbs", "<version>"` to the scratch clone) or write a small Gemfile in
scratch with `gem "<gem>", path: "<clone>"` plus the test gems, and point
`BUNDLE_GEMFILE` at it. Native deps may need system packages
(e.g. `libcurl4-openssl-dev` for curb/patron).

1. Run the suite **without** checks; note the failure count (should be 0).
2. Run it with checks in log mode:

```
cd <clone> && GEM_HOME=$W/gemhome GEM_PATH=$W/gemhome BUNDLE_GEMFILE=… \
  $TOOLS/exe/gem-types check -s $W/sig/gems/<gem>/<ver> -t "Foo,Foo::*" \
    -d rspec -o $W/work/<gem>-suite -- bundle exec rspec --format progress
```

3. Check `<prefix>.checked.tsv` is non-empty (proves hooks were active) and
   read `<prefix>.errors.tsv`: one line per distinct error with a count and
   the first test frame. Overload errors include the argument classes.
4. Compare failures with step 1. New failures are either type errors that
   changed behavior or tool artifacts (section 5).

`gem-types verify` also prints:

- **declared methods the test suite never called** (from `-c` during the
  checked run): these need a call in your verification script.
- **possibly too wide**: per parameter and return type, union members
  never matched by a value the suite passed or got back, and `untyped`
  where only concrete types were seen (uses tracepoint evidence from
  `collect` and the ancestors of observed classes, so `Numeric` matches an
  `Integer`). Tests rarely cover every accepted type; check each line
  against the source and keep what the code really accepts.

`rbs_check.sh` also loads `rbs_hook_fix.rb`, so classes or modules that
define their own `method` (e.g. `XPath`, extended with `XPath::DSL`) can be
checked; rbs/test otherwise fails at load time on them. `coverage` counts a
module's instance method as called when it was called on a class or module
that extends it (`extend Memoist`, `extend XPath::DSL`).

`gem-types live --workdir W --sig <rbs> --test-cmd "<cmd>"` makes those
gaps visible: it reruns the command with every return and attr type made
`bot` and lists the declarations that never failed. Classes outside the
gem's namespace that the RBS reopens (String, Kernel, ...) are added to the
targets with only the declared methods hooked (`RBS_TEST_ONLY_METHODS`,
honoured by `rbs_check.sh`), so a gem's core extensions are checked without
wrapping every core method (which made awesome_print's run hang). In the first five gems
it found Struct accessors (not hooked), Enumerable methods inherited by a
Hash subclass, and a method that ends in `exec`.

rbs/test installs its hooks when a class body ends, so methods a gem adds
to an existing class without reopening it (a top-level `def IPAddress`,
`String.class_eval`, `define_method`) were never checked. `rbs_check.sh`
now also installs the hooks when such a method is added to a target class.

Runtime checks only hook methods a class defines itself: a declaration that
overrides an inherited method's type (e.g. `map` on a Hash subclass whose
`each` yields values) is not checked at runtime. Check those with
assertions on what the method yields and returns.

`verify` fails (non-zero exit, `VERIFY FAILED: ...`) instead of reporting
success when the RBS does not parse (exit 2), when Steep did not finish or
reports errors in the signatures themselves, when a declared alias or
superclass does not match the gem, or when the checked test run is
incomplete (`CHECKED RUN INCOMPLETE`: no tests or no type checks counted,
fewer tests than the plain run, more failures, errors outside of
examples). An incomplete run is never written up as "no type errors", in
verify's own PR lines or in `pr-text`. Test commands run under a timeout
(`GEM_TYPES_TEST_TIMEOUT`, default 1800 seconds).

`verify` also lints the RBS against the source for two mistakes reviews
found: an `opts = {}` method declared with keywords only, and methods that
refer to `Fixnum`/`Bignum` (NameError on Ruby 3.2+).

Runs where the test command starts one Ruby process per test file are
counted whole: every process appends to the result files, which
`rbs_check.sh` clears first.

## 3b. Check declarations against the gem itself

```
$TOOLS/exe/gem-types exists --workdir W --sig <gem_rbs_collection>/gems/foo/1.2/foo.rbs
$TOOLS/exe/gem-types steep  --workdir W --sig <same> [--library json,uri]
```

- `exists` loads the gem and checks every declared method, class/module
  kind and superclass. It catches declarations of methods that do not exist
  (runtime checks never call them, and `bin/test` cannot tell).
- `steep` type-checks the gem's own `lib/` against the signatures and lists
  the diagnostics where code and signatures disagree, per method, then the
  methods defined but not declared. Expect noise: a `def m(*args)`
  implementation with precise overloads in RBS gives
  `DifferentMethodParameterKind`, which is fine.

## 4. Triage

| What you see | Usually | Action |
|---|---|---|
| Test asserts an exception for bad input (`expect { x(42) }.to raise_error`) | Negative test | Ignore — rejecting it is correct |
| Value is a test double / hand-made mock class / dummy (`5`, `:other`, `"delegated value"`) | Test scaffolding | Ignore |
| The gem's documented API or its own tests use the value as a normal case (e.g. `scale(nil)`, adding an Expander to an Expander) | **Real RBS bug** | Widen the type, add a `_test` line, rerun |
| Library code (not the test) passes the value, e.g. a symbol only used in a workaround path | **Real** if reachable by users | Add it, with a comment |
| Internal call reaches a declared method with a wider type via `super` or a shared implementation | **Real** for the runtime checker; fix the base declaration and keep subclasses narrow | Widen the base, narrow overrides |
| Delegator or Hash-like object passed internally where `Request`/`Hash` is declared | Gem's duck typing | Usually keep the public type; mention it |
| Type from another gem (e.g. ActiveSupport `TimeWithZone`) | Out of scope without a dependency | Keep; mention it |
| Extra argument the gem silently ignores | RBS stricter than runtime | Keep; mention it |
| Core-class methods (`Date.parse`, `Time.local`) fail | Core RBS, not yours | Ignore unless it is your alias |

After fixing: `bin/test`, rubocop, re-export the RBS, rerun both the script
and the suite, and confirm the specific errors are gone.

## 5. Tool limits and workarounds

- **`__callee__`-based aliases** (e.g. mustermann `alias_method :&, :|`
  dispatching on `__callee__`): the hook renames the method, so behavior and
  operator change. Errors and failures there are artifacts; verify those
  methods by running without hooks.
- **Blocks are wrapped**: arity becomes -1 and the Proc's identity/source
  location changes. Code that checks `block.arity`, compares procs, or
  reports hook locations will fail. Artifact.
- **`undef`'d methods on delegators** (e.g. `DelegateClass` with
  `undef method`): the hook cannot alias them and the whole run aborts at
  load. Make a copy of the RBS without that declaration for the run, put the
  class in `-k` for the main run, and test that method by hand.
- **`RBS_TEST_SKIP` needs absolute names**: `-k "::Foo::Bar"`.
- **Do not put `Proc`, `Method` or `UnboundMethod` in `-t`**: rbs/test uses
  them itself and recurses into `SystemStackError`. Methods a gem adds to
  them through an included module are still checked when the module is a
  target (e.g. `-t "MethodSource,MethodSource::*"`).
- **Overrides are checked only where declared**: if the RBS declares a
  method only on an included module, a class's own override of it is not
  hooked. Declare the method on the class too when its implementation
  differs (coverage still counts the module's declaration as called).
- **Setters**: the checker validates the method's real return value, not the
  assignment expression's value.
- `RBS_TEST_DOUBLE_SUITE` (`-d`) only skips rspec/minitest doubles, not
  hand-written fakes.
