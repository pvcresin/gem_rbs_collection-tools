# Commit message (= PR description)

ruby/gem_rbs_collection takes one gem per PR, and the PR title and body
are the single commit's subject and body. Keep it plain ASCII (no
smart quotes, dashes or emoji, no HTML entities), wrap at 72 columns,
and add no trailers (Co-Authored-By, Signed-off-by) or "Generated with"
lines. `gem-types msg-check` checks all of this, plus method names the
prose mentions that the RBS does not declare and numbers that differ
from the saved verify/live results. `gem-types ship` runs it again
before committing.

Start from `gem-types pr-text` (it fills References with the gem's own
release tag, monorepo subdirectory included) and rewrite the bullets
in words.

## Layout

1. Title: `Add RBS for <gem> <major.minor>` (or `Update RBS for ...`).
2. What the gem is, in one sentence, then what is typed: the main
   classes with their method names, in bullets or a short paragraph.
   Name only methods that are declared.
3. Design choices a reviewer would ask about: interfaces for duck-typed
   arguments, nilable returns and why, untyped where values really are
   arbitrary, types that come from another gem in the collection.
4. What is left out and why (internals, @api private, a dependency
   whose RBS is a separate PR, a class that needs a gem that is not a
   dependency).
5. `The gem does not ship RBS (no sig/ in the <version> package).`
6. `## Verification` with the numbers from verify and live:
   - `bin/test`, RuboCop, `rbs parse` and strict_rubocop_config.rb pass.
   - Reviewed against the source; every declared method, class and
     module exists in the loaded gem.
   - Called every declared method with runtime type checking
     (`rbs/test/setup`): N/M declarations fail when their return types
     are replaced with `bot` (name the others and why).
   - Ran the gem's own test suite with runtime type checking: X
     examples, Y type checks; then what the type errors are (negative
     tests, test doubles, mock values) and, if some tests fail only
     under the checker, their cause (verify lists them with a guess;
     confirm each).
7. `## References` with the tag URL.

## Example

```
Add RBS for websocket-extensions 0.3

websocket-extensions negotiates WebSocket extensions (such as
permessage-deflate) for websocket-driver. This adds WebSocket::Extensions
(add, generate_offer, activate, generate_response, valid_frame_rsv,
process_incoming_message, process_outgoing_message, close), Parser
(parse_header, serialize_params), Offers and ExtensionError.

Extension plugins, their sessions and frames are duck-typed, so they
are interfaces (_Extension, _ClientSession, _ServerSession, _Frame)
following the README. The library passes messages to the sessions
without reading them, so process_*_message take any object; _Message
documents the README's message for session implementations.

The private methods and the parser's regexp constants are left out.

The gem does not ship RBS (no sig/ in the 0.3.0 package).

## Verification

- `bin/test`, RuboCop, `rbs parse` and strict_rubocop_config.rb pass.
- Reviewed against the source; every declared method, class and module
  exists in the loaded gem.
- Called every declared method with runtime type checking
  (`rbs/test/setup`): 17/17 declarations (all but the initialize
  methods) fail when their return types are replaced with `bot`.
- Ran the gem's own test suite with runtime type checking: 67 examples,
  269 type checks, no type errors.

## References

- https://github.com/faye/websocket-extensions-ruby/tree/0.3.0
```
