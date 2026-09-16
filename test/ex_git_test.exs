defmodule ExGitTest do
  use ExUnit.Case, async: false

  alias ExGit.GitCLI

  @identity [name: "ExGit Test", email: "exgit@example.com"]

  setup do
    dir = GitCLI.tmp_dir("repo")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "nif is loaded" do
    assert ExGit.nif_loaded?()
  end

  test "init creates a main-branch repository comparable to git init", %{dir: dir} do
    path = Path.join(dir, "app")
    assert {:ok, repo} = ExGit.init(path)
    assert File.dir?(Path.join(path, ".git"))
    assert {:ok, :unborn} = match_branch(repo)
    assert {:ok, workdir} = ExGit.workdir(repo)
    assert Path.expand(workdir) |> realpath() == Path.expand(path) |> realpath()

    cli = Path.join(dir, "cli")
    GitCLI.init!(cli)
    assert File.read!(Path.join(path, ".git/HEAD")) == File.read!(Path.join(cli, ".git/HEAD"))
  end

  test "init refuses to reinitialize", %{dir: dir} do
    path = Path.join(dir, "app")
    assert {:ok, _} = ExGit.init(path)
    assert {:error, {_code, message}} = ExGit.init(path)
    assert is_binary(message) and byte_size(message) > 0
  end

  test "open does not walk above the exclusive ceiling into a parent repository", %{dir: dir} do
    GitCLI.init!(dir)
    workspace = Path.join(dir, "workspace")
    nested = Path.join(workspace, "nested")
    File.mkdir_p!(nested)
    ceiling = exclusive_parent(workspace)

    assert {:error, {:not_found, _}} = ExGit.open(nested, ceiling: ceiling)
    assert {:error, {:not_found, _}} = ExGit.open(workspace, ceiling: ceiling)

    inner = Path.join(dir, "inner")
    GitCLI.init!(inner)
    nested_inner = Path.join(inner, "src")
    File.mkdir_p!(nested_inner)

    assert {:ok, repo} = ExGit.open(nested_inner, ceiling: exclusive_parent(inner))
    assert {:ok, workdir} = ExGit.workdir(repo)
    assert Path.expand(workdir) |> realpath() == Path.expand(inner) |> realpath()
  end

  test "open reads a git-cli repository", %{dir: dir} do
    GitCLI.init!(dir)
    GitCLI.write!(dir, "README.md", "hi\n")
    GitCLI.git!(dir, ["add", "README.md"])
    GitCLI.git!(dir, ["commit", "-m", "first"])

    assert {:ok, repo} = ExGit.open(dir)
    assert {:ok, "main"} = match_branch(repo)
    assert {:ok, [%{oid: oid, summary: "first"}]} = ExGit.log(repo, limit: 1)
    assert oid == GitCLI.rev_parse!(dir, "HEAD")
  end

  test "status matches git porcelain for untracked, staged, and modified files", %{dir: dir} do
    GitCLI.init!(dir)
    {:ok, repo} = ExGit.open(dir)

    GitCLI.write!(dir, "lib/app.ex", "defmodule App do\nend\n")
    assert {:ok, status} = ExGit.status(repo)
    assert_entry(status, "lib/app.ex", staged: nil, unstaged: :new)
    porcelain = GitCLI.git!(dir, ["status", "--porcelain=v1", "-uall"])
    assert porcelain =~ "?? lib/app.ex"

    assert :ok = ExGit.add(repo, "lib/app.ex")
    assert {:ok, status} = ExGit.status(repo)
    assert_entry(status, "lib/app.ex", staged: :new, unstaged: nil)
    assert GitCLI.porcelain(dir) =~ "A  lib/app.ex"

    GitCLI.write!(dir, "lib/app.ex", "defmodule App do\n  def ok, do: :ok\nend\n")
    assert {:ok, status} = ExGit.status(repo)
    assert_entry(status, "lib/app.ex", staged: :new, unstaged: :modified)
    porcelain = GitCLI.porcelain(dir)
    assert porcelain =~ "AM lib/app.ex" or porcelain =~ "A  lib/app.ex"
  end

  test "add, commit, log, and reset follow the agent edit loop", %{dir: dir} do
    assert {:ok, repo} = ExGit.init(dir)
    GitCLI.write!(dir, "mix.exs", "defmodule Demo.MixProject do\nend\n")

    System.put_env("GIT_AUTHOR_NAME", "Env User")
    System.put_env("GIT_AUTHOR_EMAIL", "env@example.com")

    on_exit(fn ->
      System.delete_env("GIT_AUTHOR_NAME")
      System.delete_env("GIT_AUTHOR_EMAIL")
    end)

    assert {:error, {:invalid, _}} = ExGit.commit(repo, "wip")
    assert :ok = ExGit.add(repo, ["mix.exs"])
    assert {:ok, oid1} = ExGit.commit(repo, "init project", @identity)
    assert {:ok, [%{oid: ^oid1, summary: "init project"}]} = ExGit.log(repo)

    assert {:error, {:nothing_to_commit, _}} = ExGit.commit(repo, "again", @identity)

    GitCLI.write!(dir, "lib/demo.ex", "defmodule Demo do\nend\n")
    assert :ok = ExGit.add(repo, "lib/demo.ex")
    assert {:ok, _oid2} = ExGit.commit(repo, "add demo", @identity)
    assert {:ok, log} = ExGit.log(repo)
    assert Enum.map(log, & &1.summary) == ["add demo", "init project"]

    assert :ok = ExGit.reset(repo, :mixed, oid1)
    assert GitCLI.rev_parse!(dir, "HEAD") == oid1
    assert {:ok, status} = ExGit.status(repo)
    assert_entry(status, "lib/demo.ex", staged: nil, unstaged: :new)

    assert :ok = ExGit.add(repo, "lib/demo.ex")
    assert :ok = ExGit.reset(repo, ["lib/demo.ex"])
    assert {:ok, status} = ExGit.status(repo)
    assert_entry(status, "lib/demo.ex", staged: nil, unstaged: :new)
  end

  test "diff HEAD includes unstaged worktree edits like git diff HEAD", %{dir: dir} do
    GitCLI.init!(dir)
    GitCLI.write!(dir, "a.txt", "one\n")
    GitCLI.git!(dir, ["add", "a.txt"])
    GitCLI.git!(dir, ["commit", "-m", "one"])
    GitCLI.write!(dir, "a.txt", "two\n")

    {:ok, repo} = ExGit.open(dir)
    assert {:ok, patch} = ExGit.diff(repo)
    assert patch =~ "-one"
    assert patch =~ "+two"
    cli = GitCLI.git!(dir, ["diff", "HEAD"])
    assert normalize_diff(patch) == normalize_diff(cli)
  end

  test "branch create and checkout keep HEAD aligned with git", %{dir: dir} do
    assert {:ok, repo} = ExGit.init(dir)
    GitCLI.write!(dir, "README", "v1\n")
    assert :ok = ExGit.add(repo, "README")
    assert {:ok, _} = ExGit.commit(repo, "v1", @identity)

    assert :ok = ExGit.create_branch(repo, "feature")
    assert {:ok, branches} = ExGit.branches(repo)
    names = Enum.map(branches, & &1.name) |> Enum.sort()
    assert names == ["feature", "main"]
    assert Enum.any?(branches, &(&1.name == "main" and &1.current?))

    assert :ok = ExGit.checkout(repo, "feature")
    assert GitCLI.current_branch(dir) == "feature"
    assert {:ok, "feature"} = match_branch(repo)

    GitCLI.write!(dir, "README", "v2\n")
    assert :ok = ExGit.add(repo, "README")
    assert {:ok, _} = ExGit.commit(repo, "v2", @identity)

    assert :ok = ExGit.checkout(repo, "main")
    assert File.read!(Path.join(dir, "README")) == "v1\n"
    assert GitCLI.current_branch(dir) == "main"
  end

  test "hard reset restores the worktree to the target commit", %{dir: dir} do
    assert {:ok, repo} = ExGit.init(dir)
    GitCLI.write!(dir, "f.txt", "a\n")
    assert :ok = ExGit.add(repo, "f.txt")
    {:ok, oid} = ExGit.commit(repo, "a", @identity)
    GitCLI.write!(dir, "f.txt", "b\n")
    assert :ok = ExGit.add(repo, "f.txt")
    {:ok, _} = ExGit.commit(repo, "b", @identity)

    assert :ok = ExGit.reset(repo, :hard, oid)
    assert File.read!(Path.join(dir, "f.txt")) == "a\n"
    assert GitCLI.rev_parse!(dir, "HEAD") == oid
  end

  test "two handles serialize writes to the same on-disk repository", %{dir: dir} do
    assert {:ok, repo_a} = ExGit.init(dir)
    GitCLI.write!(dir, "a.txt", "seed\n")
    assert :ok = ExGit.add(repo_a, "a.txt")
    assert {:ok, _} = ExGit.commit(repo_a, "seed", @identity)
    assert {:ok, repo_b} = ExGit.open(dir)

    parent = self()

    pid_a =
      spawn(fn ->
        File.write!(Path.join(dir, "a.txt"), "from-a\n")
        send(parent, {:ready, :a})

        receive do
          :go ->
            :ok = ExGit.add(repo_a, "a.txt")
            {:ok, oid} = ExGit.commit(repo_a, "from a", @identity)
            send(parent, {:done, :a, oid})
        end
      end)

    pid_b =
      spawn(fn ->
        send(parent, {:ready, :b})

        receive do
          :go ->
            File.write!(Path.join(dir, "b.txt"), "from-b\n")
            :ok = ExGit.add(repo_b, "b.txt")
            {:ok, oid} = ExGit.commit(repo_b, "from b", @identity)
            send(parent, {:done, :b, oid})
        end
      end)

    assert_receive {:ready, :a}, 1_000
    assert_receive {:ready, :b}, 1_000
    send(pid_a, :go)
    send(pid_b, :go)

    results =
      for _ <- 1..2 do
        assert_receive {:done, who, oid}, 5_000
        {who, oid}
      end

    assert length(results) == 2
    assert {:ok, log} = ExGit.log(repo_a, limit: 3)
    summaries = Enum.map(log, & &1.summary)
    assert "from a" in summaries
    assert "from b" in summaries
    assert GitCLI.rev_parse!(dir, "HEAD") in Enum.map(results, &elem(&1, 1))
  end

  test "clone fetch pull and push work against a local origin", %{dir: dir} do
    seed = Path.join(dir, "seed")
    origin = Path.join(dir, "origin.git")
    clone_a = Path.join(dir, "a")
    clone_b = Path.join(dir, "b")
    GitCLI.init!(seed)
    GitCLI.write!(seed, "README", "v1\n")
    GitCLI.git!(seed, ["add", "README"])
    GitCLI.git!(seed, ["commit", "-m", "v1"])
    GitCLI.git!(dir, ["clone", "--bare", seed, origin])

    assert {:error, {:invalid, _}} = ExGit.clone("ssh://git@example.com/repo.git", clone_a)
    assert {:ok, repo_a} = ExGit.clone(origin, clone_a)
    assert File.read!(Path.join(clone_a, "README")) == "v1\n"

    GitCLI.write!(clone_a, "README", "v2\n")
    assert :ok = ExGit.add(repo_a, "README")
    assert {:ok, _} = ExGit.commit(repo_a, "v2", @identity)
    assert :ok = ExGit.push(repo_a)

    assert {:ok, repo_b} = ExGit.clone(origin, clone_b)
    assert File.read!(Path.join(clone_b, "README")) == "v2\n"
    assert :up_to_date = ExGit.pull(repo_b)

    GitCLI.write!(clone_a, "README", "v3\n")
    assert :ok = ExGit.add(repo_a, "README")
    assert {:ok, _} = ExGit.commit(repo_a, "v3", @identity)
    assert :ok = ExGit.push(repo_a)

    assert :ok = ExGit.fetch(repo_b)
    assert :fast_forward = ExGit.pull(repo_b)
    assert File.read!(Path.join(clone_b, "README")) == "v3\n"
  end

  test "owner process death closes the native repository", %{dir: dir} do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, repo} = ExGit.init(dir)
        send(parent, {:repo, repo})
        receive do: (:block -> :ok)
      end)

    assert_receive {:repo, repo}, 1_000
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    assert {:error, {:closed, _}} = ExGit.status(repo)
  end

  defp exclusive_parent(path) do
    parent = Path.dirname(Path.expand(path))
    if parent == Path.expand(path), do: path, else: parent
  end

  defp realpath(path) do
    abs = Path.expand(path)

    case System.cmd("realpath", [abs], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> abs
    end
  end

  defp match_branch(repo) do
    with {:ok, %{branch: branch}} <- ExGit.status(repo), do: {:ok, branch}
  end

  defp assert_entry(%{entries: entries}, path, staged: staged, unstaged: unstaged) do
    entry = Enum.find(entries, &(&1.path == path))
    assert entry, "missing status entry for #{path}, got #{inspect(entries)}"
    assert entry.staged == staged
    assert entry.unstaged == unstaged
  end

  defp normalize_diff(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&(&1 =~ ~r/^(index |diff --git |--- |\+\+\+ )/))
    |> Enum.join("\n")
    |> String.trim_trailing()
  end
end
