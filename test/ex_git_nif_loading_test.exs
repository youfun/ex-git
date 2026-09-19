defmodule ExGit.NIFLoadingTest do
  use ExUnit.Case, async: true

  for {setting, value} <- [
        nif_path: "/nonexistent/ex_git_nif",
        cacertfile: "/nonexistent/ex_git_cacerts.pem"
      ] do
    test "invalid #{setting} fails loading instead of silently falling back" do
      code = """
      Application.put_env(:ex_git, #{inspect(unquote(setting))}, #{inspect(unquote(value))})
      {:error, :on_load_failure} = Code.ensure_loaded(ExGit.NIF)
      """

      # A separate VM is necessary: a loaded NIF cannot be reconfigured.
      {output, status} =
        System.cmd(
          System.find_executable("elixir"),
          ["-pa", Path.join(Mix.Project.build_path(), "lib/ex_git/ebin"), "-e", code],
          stderr_to_stdout: true
        )

      assert status == 0, output
    end
  end
end
