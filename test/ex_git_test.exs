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

    System.delete_env("GIT_AUTHOR_NAME")
    System.delete_env("GIT_AUTHOR_EMAIL")
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
