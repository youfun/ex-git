# ExGit

BEAM libgit2 bindings for **local** Git on desktop, Android, and iOS.

This is the independent mobile Git library intended for Sigil: the agent edit
loop needs persistent history (`status` / `diff` / `commit` / rollback) without
spawning the Git CLI. iOS apps cannot create subprocesses, so libgit2 is the
shared native core.

```text
Agent git tool
      │
      ▼
Sigil.Git adapter          ← path ACL, tool protocol, UI, credentials
      │
      ▼
ExGit                      ← this package
      │
      ▼
libgit2 ── Android / iOS
```

## Phase 1 API

Local working-tree history only:

| Function | Role in the agent loop |
| --- | --- |
| `init/1`, `open/1` | Attach to a managed workspace |
| `status/1`, `diff/1` | Review edits before/after a change |
| `add/2`, `reset/2` | Stage or unstage |
| `commit/3`, `log/2` | Persist history after compile/test |
| `create_branch/3`, `checkout/3`, `branches/1` | Light local branching |

Remote HTTPS:

| Function | Notes |
| --- | --- |
| `clone/3` | `http(s)` or local path. Optional `username`/`password` via callback. A PAT alone uses username `x-access-token` |
| `remote_add/2`, `remote_add/3`, `remote_set_url/3`, `remotes/1` | Add or rewrite an `http(s)` / local remote. Two-arg `remote_add` names it `origin` |
| `fetch/2`, `push/2` | Default remote `origin`. Push sets upstream on the current branch |
| `pull/2` | Fetch + fast-forward only |

GitHub from a local `init`:

```elixir
{:ok, repo} = ExGit.init(workspace)
:ok = ExGit.add(repo, ["README.md"])
{:ok, _} = ExGit.commit(repo, "first", name: "Agent", email: "agent@local")
:ok = ExGit.remote_add(repo, "https://github.com/owner/repo.git")
:ok = ExGit.push(repo, password: System.fetch_env!("GITHUB_TOKEN"))
```

Not supported: SSH, merge commits, tokens in the URL.

## Design rules

- Android and iOS expose the same Elixir API and semantics.
- Mutating operations on one repository handle are serialized (libgit2 index
  is not thread-safe).
- The NIF resource is bound to the process that opened it; that process dying
  closes the native repository.
- Author identity is passed into `commit/3`. It is never written to a remote
  URL, log line, or Git config.
- Tests compare observable results with the desktop Git CLI.

## Build

Needs a host libgit2 (Homebrew: `brew install libgit2`) and Elixir 1.18+.

```elixir
def deps do
  [{:ex_git, path: "../ex-git"}]
end
```

```text
mix deps.get
mix test
```

A GitHub HTTPS probe is skipped unless both `EX_GIT_GITHUB_URL` (an HTTPS repo the token can push to) and `EX_GIT_GITHUB_TOKEN` are set. It creates a unique branch and does not delete it.

Mobile ABI packaging lives under `native/android` and `native/ios`. Those
cross-builds are not required for desktop development.

## Usage

```elixir
{:ok, repo} = ExGit.init(workspace)
# agent edits files
:ok = ExGit.add(repo, ["lib/demo.ex"])
{:ok, oid} = ExGit.commit(repo, "fix compile",
  name: "Sigil Agent",
  email: "agent@local"
)
{:ok, patch} = ExGit.diff(repo)
{:ok, history} = ExGit.log(repo, limit: 20)
```
