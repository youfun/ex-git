defmodule ExGit.Repo do
  @moduledoc """
  An opened Git repository.

  The native handle is bound to the process that called `ExGit.init/1` or
  `ExGit.open/1`. When that process exits, libgit2 resources are closed.
  """

  @enforce_keys [:ref]
  defstruct [:ref]

  @opaque t :: %__MODULE__{ref: reference()}
end
