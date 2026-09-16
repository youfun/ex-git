defmodule ExGit.GitCLI do
  @moduledoc false

  import ExUnit.Assertions

  def tmp_dir(prefix) do
    base = Path.join(System.tmp_dir!(), "ex-git-#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    base
  end

  def git!(dir, args, opts \\ []) do
    env =
      [
        {"GIT_AUTHOR_NAME", "ExGit Test"},
        {"GIT_AUTHOR_EMAIL", "exgit@example.com"},
        {"GIT_COMMITTER_NAME", "ExGit Test"},
        {"GIT_COMMITTER_EMAIL", "exgit@example.com"},
        {"GIT_CONFIG_NOSYSTEM", "1"},
        {"GIT_TERMINAL_PROMPT", "0"},
        {"HOME", dir}
      ]

    {out, status} =
      System.cmd("git", args,
        cd: dir,
        env: env,
        stderr_to_stdout: true
      )

    unless status == 0 or Keyword.get(opts, :allow_fail, false) do
      flunk("git #{Enum.join(args, " ")} failed (#{status}):\n#{out}")
    end

    String.trim_trailing(out)
  end

  def init!(dir) do
    File.mkdir_p!(dir)
    git!(dir, ["-c", "init.defaultBranch=main", "init"])
    git!(dir, ["config", "user.name", "ExGit Test"])
    git!(dir, ["config", "user.email", "exgit@example.com"])
    dir
  end

  def write!(dir, rel, contents) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  def porcelain(dir) do
    git!(dir, ["status", "--porcelain=v1", "-b"])
  end

  def log_oneline(dir) do
    git!(dir, ["log", "--pretty=%H %s"], allow_fail: true)
  end

  def rev_parse!(dir, spec) do
    git!(dir, ["rev-parse", spec])
  end

  def current_branch(dir) do
    git!(dir, ["rev-parse", "--abbrev-ref", "HEAD"])
  end
end
