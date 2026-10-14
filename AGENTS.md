# Kibble agent entry point

The application is in this public repository. Maintainer instructions, plans,
protocol research, journals, and handoffs live in the separate **private**
repository `Entersprite/KibbleDocs`.

Before maintainer work, locate that checkout and read its `AGENTS.md` and
`CLAUDE.md`, then follow its current reading order. Use `KIBBLE_DOCS_PATH` if set;
otherwise use `../kibbledocs` next to the main Kibble checkout. In a Git worktree,
find the main checkout from `git rev-parse --git-common-dir` and look beside it.
Resolve paths from the checkout, not from a package's working directory.

Before editing application or package code, read the private checkout's
`docs/design/current-architecture-and-rules.md` and the relevant module section
of `docs/design/module-architecture-guide.md`. Follow that guide's pre-edit and
completion checklist. These references apply to every maintainer code change,
not only work described as an architecture change.

On a fresh machine, clone both repositories as sibling folders:

```sh
git clone git@github.com:Entersprite/Kibble.git kibble
git clone git@github.com:Entersprite/KibbleDocs.git kibbledocs
cd kibble
./scripts/setup-private-docs.sh
```

Use your configured personal SSH alias if needed. The setup script can also
clone the missing private checkout using the public checkout's GitHub transport.
It creates ignored links for the existing `docs/`, `Spikes/`, `.superpowers/`,
and `reference/` paths. It never replaces existing files or directories.

Keep all private content and detailed working instructions in KibbleDocs. These
public entry points contain discovery instructions only. Do not force-add the
ignored links or copy private material into public files, issues, PRs, or commit
messages. Commit documentation in its own repository and verify its remote is
still private before pushing. Never change a repository's visibility.

If private access is unavailable, state that explicitly. Public contributors can
use `README.md` and the source to work on the app; maintainer work that depends on
private plans or rules must wait for access. Do not invent missing instructions.
