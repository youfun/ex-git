defmodule ExGit do
  @moduledoc """
  Local Git operations for BEAM on desktop, Android, and iOS.

  Phase 1 covers working-tree history around an agent edit loop:

      init/open → status/diff → add/reset → commit/log → branch/checkout

  HTTPS and local remotes support clone/fetch/push and fast-forward pull.
  Local `init` repositories can `remote_add` an origin and push; a successful
  push sets upstream so the next `pull` works. Credentials are passed per
  call and never written to the remote URL, logs, or Git config. A password
  (PAT) alone is sent as GitHub's `x-access-token` username. SSH and merge
  commits are out of scope.

  Mutating calls on the same on-disk repository are serialized across
  handles. A handle is bound to the process that opened it.
  """

  alias ExGit.NIF
  alias ExGit.Repo

  @type error :: {:error, {atom(), String.t()}}
  @type repo :: Repo.t()
  @type path :: Path.t()
  @type oid :: String.t()

  @type status_entry :: %{
          required(:path) => String.t(),
          required(:staged) => status_kind | nil,
          required(:unstaged) => status_kind | nil,
          optional(:old_path) => String.t()
        }

  @type status_kind ::
          :new
          | :modified
          | :deleted
          | :renamed
          | :typechange
          | :conflicted
          | :ignored
          | :unreadable

  @type status :: %{
          branch: String.t() | :unborn | :detached,
          entries: [status_entry()]
        }

  @type commit_info :: %{
          oid: oid(),
          message: String.t(),
          summary: String.t(),
          author: %{name: String.t(), email: String.t(), time: integer()}
        }

  @type branch :: %{name: String.t(), current?: boolean()}

  @type remote :: %{name: String.t(), url: String.t()}

  @doc "True once the libgit2 NIF is loaded."
  @spec nif_loaded?() :: boolean()
  def nif_loaded?, do: NIF.loaded()

  @doc """
  Initialize a repository at `path`.

  Creates missing parent directories. Refuses to reinitialize an existing
  repository. The default branch is `main`.
  """
  @spec init(path()) :: {:ok, repo()} | error()
  def init(path) when is_binary(path) do
    wrap_repo(NIF.init(Path.expand(path)))
  end

  @doc """
  Open an existing repository at `path` (a workdir or `.git` directory).

  Options:

    * `:ceiling` — exclusive upper bound for discovery (`GIT_CEILING_DIRECTORIES`).
      libgit2 will not enter this directory while walking parents, so a
      repository *at* `ceiling` is still found, and a repository *above* it
      is not. Hosts should pass `Path.dirname(workspace)` so a repo at the
      workspace root is found without walking out of the workspace.
  """
  @spec open(path(), keyword()) :: {:ok, repo()} | error()
  def open(path, opts \\ []) when is_binary(path) do
    expanded = Path.expand(path)

    ceiling =
      case Keyword.get(opts, :ceiling) do
        nil -> default_ceiling(expanded)
        value -> Path.expand(value)
      end

    wrap_repo(NIF.open(expanded, ceiling))
  end

  @doc "Working-tree path for an opened repository."
  @spec workdir(repo()) :: {:ok, String.t()} | error()
  def workdir(%Repo{ref: ref}), do: decode(NIF.workdir(ref))

  @doc "Index and worktree status, including untracked files."
  @spec status(repo()) :: {:ok, status()} | error()
  def status(%Repo{ref: ref}), do: decode(NIF.status(ref))

  @doc """
  Unified patch text.

  * `diff(repo)` — `HEAD` to worktree including index (`git diff HEAD`)
  * `diff(repo, :worktree)` — index to worktree (`git diff`)
  * `diff(repo, :staged)` — `HEAD` to index (`git diff --cached`)
  * `diff(repo, from, to)` — tree-to-tree
  """
  @spec diff(repo()) :: {:ok, String.t()} | error()
  def diff(%Repo{ref: ref}), do: decode(NIF.diff(ref, 0, "", ""))

  @spec diff(repo(), :worktree | :staged) :: {:ok, String.t()} | error()
  def diff(%Repo{ref: ref}, :worktree), do: decode(NIF.diff(ref, 1, "", ""))
  def diff(%Repo{ref: ref}, :staged), do: decode(NIF.diff(ref, 2, "", ""))

  @spec diff(repo(), String.t(), String.t()) :: {:ok, String.t()} | error()
  def diff(%Repo{ref: ref}, from, to) when is_binary(from) and is_binary(to) do
    decode(NIF.diff(ref, 3, from, to))
  end

  @doc "Stage `paths` (`git add`). An empty list stages the whole worktree."
  @spec add(repo(), path() | [path()]) :: :ok | error()
  def add(%Repo{ref: ref}, paths) do
    decode(NIF.add(ref, List.wrap(paths)))
  end

  @doc """
  Reset.

  * `reset(repo, :mixed | :soft | :hard)` — reset `HEAD`
  * `reset(repo, :mixed | :soft | :hard, target)`
  * `reset(repo, paths)` — unstage pathspecs (`git reset -- path`)
  """
  @spec reset(repo(), :soft | :mixed | :hard | [path()] | path()) :: :ok | error()
  def reset(repo, type_or_paths), do: reset(repo, type_or_paths, "HEAD")

  @spec reset(repo(), :soft | :mixed | :hard | [path()] | path(), String.t()) :: :ok | error()
  def reset(%Repo{ref: ref}, paths, target) when is_list(paths) or is_binary(paths) do
    decode(NIF.reset(ref, 3, target, List.wrap(paths)))
  end

  def reset(%Repo{ref: ref}, type, target) when type in [:hard, :soft, :mixed] do
    code =
      case type do
        :hard -> 1
        :soft -> 2
        :mixed -> 0
      end

    decode(NIF.reset(ref, code, target, []))
  end

  @doc """
  Create a commit from the current index.

  Author identity is required and is never written to Git config.

      ExGit.commit(repo, "fix compile", name: "Agent", email: "agent@local")

  `name` and `email` are required. They are never read from the environment
  or written to Git config.
  """
  @spec commit(repo(), String.t(), keyword()) :: {:ok, oid()} | error()
  def commit(%Repo{ref: ref}, message, opts \\ []) when is_binary(message) do
    with {:ok, name} <- required_identity(opts, :name),
         {:ok, email} <- required_identity(opts, :email) do
      decode(NIF.commit(ref, message, name, email))
    end
  end

  @doc "Walk commits from `HEAD`, newest first."
  @spec log(repo(), keyword()) :: {:ok, [commit_info()]} | error()
  def log(%Repo{ref: ref}, opts \\ []) do
    decode(NIF.log(ref, Keyword.get(opts, :limit, 32)))
  end

  @doc "List local branches."
  @spec branches(repo()) :: {:ok, [branch()]} | error()
  def branches(%Repo{ref: ref}), do: decode(NIF.branches(ref))

  @doc "Create a local branch at `HEAD`."
  @spec create_branch(repo(), String.t(), keyword()) :: :ok | error()
  def create_branch(%Repo{ref: ref}, name, opts \\ []) when is_binary(name) do
    force = if Keyword.get(opts, :force, false), do: 1, else: 0
    decode(NIF.create_branch(ref, name, force))
  end

  @doc """
  Check out a local branch name, or detach `HEAD` at a revision.

  Pass `force: true` to overwrite local worktree changes.
  """
  @spec checkout(repo(), String.t(), keyword()) :: :ok | error()
  def checkout(%Repo{ref: ref}, name, opts \\ []) when is_binary(name) do
    force = if Keyword.get(opts, :force, false), do: 1, else: 0
    decode(NIF.checkout(ref, name, force))
  end

  @doc """
  Clone `url` into `path`.

  `url` must be `http://`, `https://`, `file://`, or a local filesystem path.
  Optional `username`/`password` are supplied through libgit2's credential
  callback and are never written into the URL. A password (PAT) without
  `username` is sent as GitHub username `x-access-token`.

  All network operations accept `:credential_endpoint` (scheme, host and optional
  port, without a path) to check fresh authentication challenges, including push
  targets. This disables cross-host redirects, NOT same-host port/path redirects:
  libgit2 may replay accepted credentials on other ports of the same hostname.
  Only use it with a hostname whose services are all trusted. HTTPS downgrades
  are rejected by libgit2; callers handling secrets should require HTTPS.
  """
  @spec clone(String.t(), path(), keyword()) :: {:ok, repo()} | error()
  def clone(url, path, opts \\ []) when is_binary(url) and is_binary(path) do
    wrap_repo(NIF.clone(url, Path.expand(path), auth_term(opts)))
  end

  @doc "Fetch from `remote` (default `origin`)."
  @spec fetch(repo(), keyword()) :: :ok | error()
  def fetch(%Repo{ref: ref}, opts \\ []) do
    decode(NIF.fetch(ref, remote_name(opts), auth_term(opts)))
  end

  @doc """
  Fetch and fast-forward `HEAD` to its upstream.

  Returns `:up_to_date` or `:fast_forward`. Diverged histories return
  `{:error, {:conflict, _}}` instead of creating a merge commit.
  """
  @spec pull(repo(), keyword()) :: :up_to_date | :fast_forward | error()
  def pull(%Repo{ref: ref}, opts \\ []) do
    decode(NIF.pull(ref, remote_name(opts), auth_term(opts)))
  end

  @doc """
  Push the current branch to `remote` (default `origin`).

  On success, sets the branch upstream to `remote/<branch>` so a later
  `pull/2` can fast-forward. Detached `HEAD` is pushed without changing
  upstream.
  """
  @spec push(repo(), keyword()) :: :ok | error()
  def push(%Repo{ref: ref}, opts \\ []) do
    decode(NIF.push(ref, remote_name(opts), auth_term(opts)))
  end

  @doc "List remotes as `%{name, url}` maps."
  @spec remotes(repo()) :: {:ok, [remote()]} | error()
  def remotes(%Repo{ref: ref}), do: decode(NIF.remotes(ref))

  @doc """
  Add a named remote.

  `url` must be `http://`, `https://`, `file://`, or a local filesystem path.
  Two-argument form uses the name `origin`.
  """
  @spec remote_add(repo(), String.t()) :: :ok | error()
  def remote_add(repo, url) when is_binary(url), do: remote_add(repo, "origin", url)

  @spec remote_add(repo(), String.t(), String.t()) :: :ok | error()
  def remote_add(%Repo{ref: ref}, name, url) when is_binary(name) and is_binary(url) do
    decode(NIF.remote_add(ref, name, url))
  end

  @doc "Change the fetch URL of an existing remote."
  @spec remote_set_url(repo(), String.t(), String.t()) :: :ok | error()
  def remote_set_url(%Repo{ref: ref}, name, url) when is_binary(name) and is_binary(url) do
    decode(NIF.remote_set_url(ref, name, url))
  end

  defp wrap_repo({:ok, ref}) when is_reference(ref), do: {:ok, %Repo{ref: ref}}
  defp wrap_repo(other), do: decode(other)

  defp decode(:ok), do: :ok
  defp decode(:up_to_date), do: :up_to_date
  defp decode(:fast_forward), do: :fast_forward
  defp decode({:ok, value}), do: {:ok, value}

  defp decode({:error, {code, message}}) when is_atom(code) and is_binary(message) do
    {:error, {code, message}}
  end

  defp decode({:error, reason}), do: {:error, {:error, to_string(reason)}}
  defp decode(other), do: other

  defp required_identity(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid, "author #{key} is required"}}
    end
  end

  # Exclusive ceiling: walk parents of `path`, but do not enter the parent of
  # `path` itself. A repo at `path` is found; a repo above it is not.
  defp default_ceiling(path) do
    parent = Path.dirname(path)
    if parent == path, do: path, else: parent
  end

  defp remote_name(opts), do: Keyword.get(opts, :remote, "origin")

  defp auth_term(opts) do
    pass = Keyword.get(opts, :password)
    user = Keyword.get(opts, :username)

    if is_binary(pass) and pass != "" do
      user = if is_binary(user) and user != "", do: user, else: "x-access-token"
      auth = %{username: user, password: pass}

      case Keyword.fetch(opts, :credential_endpoint) do
        {:ok, origin} -> Map.put(auth, :url, origin)
        :error -> auth
      end
    end
  end
end
