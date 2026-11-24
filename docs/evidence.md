# Gathering type evidence

## Contents
1. Prepare the workspace
2. Observe types with TracePoint (main source)
3. Static inference with tyda
4. Draft RBS
5. Lumitrace for expression-level detail
6. Reading the evidence

`$TOOLS` is the root of this repository. Examples use netrc.

## 1. Prepare

```
$TOOLS/bin/prepare_gem.sh netrc "" $SCRATCH/rbs-work/netrc
W=$SCRATCH/rbs-work/netrc
cd $W/env && GEM_HOME=$W/gemhome GEM_PATH=$W/gemhome bundle install
```

- `pkg/` is the packaged gem (what users install; read this source).
- `repo/` is upstream at the release tag. If no tag matched, clone and pick
  the commit for that release yourself.
- If `bundle exec` fails, copy missing test gems from `repo/Gemfile` into
  `env/Gemfile`. Some need system packages (e.g. `libcurl4-openssl-dev`).
- Run the suite once without any tooling and note failures; anything that
  fails here is environment, not types.

Typical test commands, from `repo/`:

```
export BUNDLE_GEMFILE=$W/env/Gemfile GEM_HOME=$W/gemhome GEM_PATH=$W/gemhome
bundle exec rspec                                   # spec/
for t in test/*_test.rb test/test_*.rb; do bundle exec ruby -Ilib -Itest $t; done   # minitest/test-unit
bundle exec rake test                               # if the Rakefile has it
```

## 2. Observe with TracePoint

```
cd $W/repo && OBSERVE_NS="Netrc,Netrc::*" OBSERVE_OUT=$W/obs-netrc.types \
  RUBYOPT="-r$TOOLS/bin/observe_types.rb" bundle exec ruby -Ilib -Itest test/test_netrc.rb
```

One output per process (`<OUT>` text, `<OUT>.json` for draft_rbs.rb). Run
each test file with its own OUT name and merge later. Text format:

```
Timecop.scale: (*args: Integer | String | Time | nil) block=no/yes -> Time | bool | raise TypeError   # 9 calls
    (Integer) -> Time
    (Integer, Time) {} -> bool
    (String) -> raise TypeError
    (nil) -> Time
```

- Each indented line is one call shape and how it ended. A shape that only
  raises is usually a negative test → leave it out of the RBS.
- Return types with a block are often the block's value (here `bool` from
  the test's block), so a generic `[T] ... { } -> T` is usually right.
- Public methods only, plus `initialize`; `OBSERVE_PRIVATE=1` for the rest.
- Array/Hash element types come from the first 5 elements.

## 3. Static inference with tyda

```
cd $W/repo && tyda lib test > $W/tyda.rbs     # library + test call sites
tyda lib > $W/tyda-lib.rbs                    # library only, to compare
tyda why ... / tyda trace ...                 # where a type came from
```

Feeding the tests adds argument types seen at call sites. Results are often
`untyped` and include private helpers; use them for structure (class vs
module, superclass, Struct members, method list) and as a cross-check, not
as the final type.

## 4. Draft

```
ruby $TOOLS/bin/draft_rbs.rb --observed $W/obs-*.types.json --tyda $W/tyda.rbs \
  [--existing <repo>/gems/netrc/0.11/netrc.rbs] --ns Netrc > $W/draft.rbs
```

Per method: observed types from calls that returned normally; else tyda;
else `untyped`, with a comment saying which source it came from and which
exceptions were seen. With `--existing`, it also lists methods the tests
call that the current RBS lacks.

Then edit by hand: name parameters, replace observed concrete types with
the intended ones (`Array[String] | Array[untyped]` → `Array[String]`),
turn block-return unions into a type parameter, drop private helpers, and
check every method in the source.

## 5. Lumitrace (expression level)

Lumitrace records the types of every expression in instrumented files.
Use it to look inside one method, not for whole signatures (it records
`Array`, not `Array[String]`).

```
cd $W/repo && LUMITRACE_ENABLE=1 LUMITRACE_ROOT=$W/repo/lib \
  LUMITRACE_COLLECT_MODE=types LUMITRACE_JSON=$W/lumi.json \
  LUMITRACE_RANGE="$W/repo/lib/netrc.rb:120-160" \
  bundle exec ruby -rlumitrace -Ilib -Itest test/test_netrc.rb
```

JSON: `{"events": [{"file", "start_line", "kind": "expr"|"arg", "name", "types": {"Integer": 3, "NilClass": 1}}]}`.
`lumitrace -h ...` writes an HTML view with values overlaid on the code.

## 6. Reading the evidence

- Tests are not users: they also pass invalid values on purpose and use
  doubles. Check where an odd type comes from (the shape lines, or the test
  file) before widening a type.
- A method never called by the tests has no runtime evidence; type it from
  the source and make sure the verification script calls it.
- When observed types and the source disagree, the source decides; when the
  README/docs promise something the tests do not exercise, prefer the
  documented contract.
