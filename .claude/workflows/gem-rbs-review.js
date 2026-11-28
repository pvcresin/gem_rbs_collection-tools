export const meta = {
  name: 'gem-rbs-review',
  description: 'Independent adversarial review of RBS files against the gem source and runtime',
  phases: [{ title: 'Review' }],
}

// args: { tools: "/path/to/gem_rbs_collection-tools",
//         items: [{ gem, ver, ns, workdir, worktree, test_cmd?, notes?, accepted? }] }
//   accepted: findings of an earlier review that were checked and kept on
//             purpose; the reviewer does not report them again
//   ver:      collection directory version, e.g. "1.4"
//   ns:       runtime check targets, e.g. "Daemons,Daemons::*,Daemonize"
//   workdir:  gem-types workdir after `gem-types run` (repo/, env/, gemhome/, draft.rbs, report.md)
//   worktree: a gem_rbs_collection worktree on branch add-<gem>
// One reviewer per item, who sees only the RBS and the gem (not how it
// was written), tries to falsify every declaration.
const T = args.tools
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

const reviewPrompt = x => `You are reviewing a proposed RBS file for the Ruby gem "${x.gem}" before it goes to ruby/gem_rbs_collection. Find declarations that are WRONG (contradict the code). Assume nothing is correct; try to falsify each one. Missing methods are fine.

RBS (read only, do not edit): ${sigdir(x)}/ . Gem source: ${x.workdir}/repo/lib (packaged copy in ${x.workdir}/pkg). Run Ruby: cd ${x.workdir}/repo && ${env(x)} bundle exec ruby -Ilib ... ; scripts go in ${x.workdir}/review/. Runtime checking: ${T}/exe/gem-types check -s <copy of the sig dir> -t "${x.ns}" -- <cmd> (it does not check inherited methods). Never execute anything from gem_rbs_collection's gems/.

For every declaration check: where it is defined (instance/singleton, include/extend, public); parameters (required/optional/rest/keywords, block required/optional, block args and self); every possible return value on every branch (nil, false vs bool, Enumerator without block, subclass vs plain Array/Hash, early return from a block); whether a parameter type rejects values the docs or the gem's own tests pass in normal use (calls that only raise should be rejected); aliases, attrs, constants, superclasses; methods that forward to another declared method (delegators, tokens.each(&blk)) must agree with it; parameters typed Hash[K, V]/Array[T] must accept the subclasses the gem itself passes (generics are invariant). Also run ${T}/exe/gem-types lint --workdir ${x.workdir} --sig ${sigdir(x)} and judge each finding against the source. Prove each suspicion with a source line or a run (command + output). Report only confirmed issues; mark unsure ones nit.${x.accepted ? `

Known and accepted (checked against the source and kept on purpose; do not report these again): ${x.accepted}` : ""}`

return await parallel(args.items.map(x => () =>
  agent(reviewPrompt(x), { label: `review:${x.gem}`, phase: 'Review', schema: REVIEW })))
