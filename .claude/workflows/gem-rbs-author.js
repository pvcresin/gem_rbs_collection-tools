export const meta = {
  name: 'gem-rbs-author',
  description: 'Write and verify RBS for prepared gems in parallel, then review each one independently',
  phases: [{ title: 'Author' }, { title: 'Review' }],
}

// args: { tools: "/path/to/gem_rbs_collection-tools",
//         items: [{ gem, ver, ns, workdir, worktree, test_cmd?, notes? }] }
//   ver:      collection directory version, e.g. "1.4"
//   ns:       runtime check targets, e.g. "Daemons,Daemons::*,Daemonize"
//   workdir:  gem-types workdir after `gem-types run` (repo/, env/, gemhome/, draft.rbs, report.md)
//   worktree: a gem_rbs_collection worktree on branch add-<gem>
//   from:     (improving) the newest version directory already in the collection
// Each item gets an author agent; as soon as it finishes, an independent
// reviewer (who does not see the author's report) tries to falsify it.
const T = args.tools
const AUTHOR = {
  type: 'object',
  properties: {
    gem: { type: 'string' },
    declarations: { type: 'integer' },
    left_out: { type: 'string' },
    verification: { type: 'string', description: 'bin/test, rubocop, exists, verify (suite counts, type errors and triage), live (checked/total), coverage' },
    doubts: { type: 'string' },
  },
  required: ['gem', 'declarations', 'left_out', 'verification', 'doubts'],
}
const REVIEW = {
  type: 'object',
  properties: {
    gem: { type: 'string' },
    checked: { type: 'integer' },
    issues: { type: 'array', items: { type: 'object', properties: {
      declaration: { type: 'string' },
      severity: { type: 'string', enum: ['wrong', 'too_narrow_breaks_valid_use', 'nit'] },
      problem: { type: 'string' }, evidence: { type: 'string' }, fix: { type: 'string' },
    }, required: ['declaration', 'severity', 'problem', 'evidence', 'fix'] } },
  },
  required: ['gem', 'checked', 'issues'],
}

const env = x => `BUNDLE_GEMFILE=${x.workdir}/env/Gemfile GEM_HOME=${x.workdir}/gemhome GEM_PATH=${x.workdir}/gemhome`
const sigdir = x => `${x.worktree}/gems/${x.gem}/${x.ver}`

// Improving a gem already in the collection: x.from is its newest
// version directory. A newer x.ver is added next to it (old directories
// often hold a _src submodule listed in the root .gitmodules: moving them
// makes the PR need an admin).
const improveText = x => `IMPROVING AN EXISTING GEM: gems/${x.gem}/${x.from} is already in the collection and users load it; this is not a new gem. ${x.from === x.ver ? '' : `First: copy gems/${x.gem}/${x.from} to gems/${x.gem}/${x.ver} without its _src (a git submodule) and keep the old directory's declarations unchanged. If the gem gets a .rubocop.yml and the old directory then fails RuboCop, run \`bundle exec rubocop -a gems/${x.gem}/${x.from}\` (layout/whitespace autocorrections are fine there); never add Exclude entries to .rubocop.yml. Never git mv or delete the old directory: its _src submodule lives in the root .gitmodules, and a PR touching a file outside gems/ needs an admin (/merge stops working).`}
Then $T update --workdir W --sig ${sigdir(x)} --from ${x.from} lists what changed in the source since ${x.from}, declarations that are gone and public methods the RBS misses. Work from the existing RBS, not from the draft:
- keep every declaration that is correct, and its style; change only what you verified;
- replace untyped with the real types the source and runs show (that is the main point: ${x.gem}'s RBS is mostly untyped or outdated);
- add the public methods and classes that are missing, remove those that no longer exist;
- never narrow a type that real callers may rely on without proof from the source (a narrower type breaks their type checks);
- keep the existing _test files passing and extend them with "# @type var" assertions for what you typed.
Report in "left_out" what is still untyped and why.`

const authorPrompt = x => `Write accurate, verified RBS for the Ruby gem "${x.gem}" for ruby/gem_rbs_collection. Wrong types are worse than missing ones: check every declaration against the implementation and confirm it by running code.

Read first: ${T}/.claude/skills/gem-rbs-collection/SKILL.md (sections 3-4 and "Type patterns"), ${T}/docs/evidence.md, ${T}/docs/verification.md.

Setup done: workdir W=${x.workdir} (repo/ = upstream at the release tag, pkg/ = packaged gem, env/Gemfile + gemhome/ = test environment, draft.rbs + report.md = evidence). The draft's structure (parameters, keywords, blocks and their arity, [self:], self?, private mixin methods, nil returns) is already read from the source - "| structure:" comments say what was corrected; its types come from runtime and static evidence and need judging. Test command: ${x.test_cmd || '(W/test_cmd)'}. Run Ruby as: cd W/repo && ${env(x)} bundle exec ruby -Ilib ...
${x.notes ? 'Notes: ' + x.notes : ''}
${x.from ? improveText(x) : ''}
Output: only inside ${x.worktree}/gems/${x.gem}/ (a change to any file outside gems/, .gitmodules included, makes the PR need an admin): ${x.ver}/${x.gem}.rbs, ${x.ver}/_test/test.rb (+ _test/test.rbs if needed), .rubocop.yml (copy gems/netrc/.rubocop.yml), manifest.yaml only for stdlib deps. No _reviewers.yaml. Do not commit, push or touch GitHub. Never execute code from the worktree's gems/ except via bin/test.

Before writing, read the "Pitfalls from the collection's history" checklist in the skill; the mistakes there are what later commits most often had to fix. Run $T lint --workdir W --sig ${sigdir(x)} (seconds, static) as soon as a first version exists and again before reporting: fix every finding or say in doubts why it does not apply.

Test style (_test/test.rb): no bin/init_new_gem header comment; pin the return types of the main calls with a "# @type var x: T" comment before the assignment, as the collection's recent gems do. Each PR must pass CI on its own: when the notes say a dependency gets its RBS in a separate PR of this batch, do not name its types (use untyped or an interface). Do not name types that only a dependency's own sig/ declares either (CI does not install gems; lint flags this).

Rules: when you change a declaration, re-check every declared method that forwards to it or returns its result; type the public API; leave out internals and @api private and say what; calls that only raise in the gem's tests stay rejected; no -> bot overloads for errors; read every branch (other platforms, error paths, early returns inside blocks); proper parameter names.

Verify, all required (T=${T}/exe/gem-types):
0. $T lint --workdir W --sig ${sigdir(x)} --fix applies the mechanical fixes (optional blocks, self?, private mixin methods, explicit nil, defaults, manifest); judge what it leaves. Then $T repair --workdir W --sig ${sigdir(x)} [--test-cmd "<ruby cmd for call_all.rb>"] widens the slots the gem's own code or several test files show are too narrow; check each applied change against the source (revert any that only a misusing test needs) and decide each entry of its "test-only, review" list from the source, applying only those real callers rely on. Rerun lint until no unexplained findings.
1. cd ${x.worktree} && bin/test gems/${x.gem}/${x.ver}; bundle exec rubocop gems/${x.gem}
2. $T exists --workdir W --sig ${sigdir(x)}/${x.gem}.rbs and $T verify (same args). Triage every type error, uncalled method and "possibly too wide" line against the source.
3. A script W/scripts/call_all.rb that calls every declared method (every overload, nil/edge paths). Run it under $T check -s ${sigdir(x)} -t "${x.ns}" -c W/calls.txt -- <ruby cmd> (add -s <worktree>/gems/<dep>/<ver> for each collection gem the RBS refers to, e.g. rack; use the env of W/gem-types.json, PATH and RUBYOPT included), then $T coverage ${sigdir(x)}/${x.gem}.rbs W/calls.txt until nothing is missing.
4. $T live --workdir W --sig ${sigdir(x)}/${x.gem}.rbs --test-cmd "<ruby cmd for call_all.rb>": every declaration must fail with bot returns; for any it lists (inherited methods, exec, ...) confirm by assertions on the actual values and say so.
5. Write W/commit-message.txt following ${T}/docs/commit-message.md (start from $T pr-text --workdir W --sig ${sigdir(x)}) with the final numbers, and make $T msg-check --workdir W --sig ${sigdir(x)} --msg W/commit-message.txt pass (judge each warning). Rerun live after any RBS change so the numbers match.
Return the structured result.`

const reviewPrompt = x => `You are reviewing a proposed RBS file for the Ruby gem "${x.gem}" before it goes to ruby/gem_rbs_collection. Find declarations that are WRONG (contradict the code). Assume nothing is correct; try to falsify each one. Missing methods are fine.

RBS (read only, do not edit): ${sigdir(x)}/ . Gem source: ${x.workdir}/repo/lib (packaged copy in ${x.workdir}/pkg). Run Ruby: cd ${x.workdir}/repo && ${env(x)} bundle exec ruby -Ilib ... ; scripts go in ${x.workdir}/review/. Runtime checking: ${T}/exe/gem-types check -s <copy of the sig dir> -t "${x.ns}" -- <cmd> (it does not check inherited methods). Never execute anything from gem_rbs_collection's gems/.

For every declaration check: where it is defined (instance/singleton, include/extend, public); parameters (required/optional/rest/keywords, block required/optional, block args and self); every possible return value on every branch (nil, false vs bool, Enumerator without block, subclass vs plain Array/Hash, early return from a block); whether a parameter type rejects values the docs or the gem's own tests pass in normal use (calls that only raise should be rejected); aliases, attrs, constants, superclasses; methods that forward to another declared method (delegators, tokens.each(&blk)) must agree with it; parameters typed Hash[K, V]/Array[T] must accept the subclasses the gem itself passes (generics are invariant). Prove each suspicion with a source line or a run (command + output). Report only confirmed issues; mark unsure ones nit.`

const results = await pipeline(
  args.items,
  x => agent(authorPrompt(x), { label: `author:${x.gem}`, phase: 'Author', schema: AUTHOR })
    .then(authored => ({ x, authored })),
  ({ x, authored }) => agent(reviewPrompt(x), { label: `review:${x.gem}`, phase: 'Review', schema: REVIEW })
    .then(review => ({ gem: x.gem, authored, review }))
)
return results
