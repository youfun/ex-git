defmodule ExGit.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_git,
      version: "0.0.4",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      deps: deps(),
      description: "BEAM libgit2 bindings for local Git on Android and iOS",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:elixir_make, "~> 0.9", runtime: false}
    ]
  end

  defp package do
    [
      files: [
        "lib",
        "c_src",
        "native",
        "Makefile",
        "mix.exs",
        "README.md",
        "LICENSE"
      ],
      licenses: ["Apache-2.0"]
    ]
  end
end
