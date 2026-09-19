defmodule ExGit.NIF do
  @moduledoc false

  @on_load :load_nif
  @nif_name ~c"ex_git_nif"

  def load_nif do
    path = :filename.join(priv_dir(), @nif_name)

    case :erlang.load_nif(path, 0) do
      :ok -> :ok
      {:error, {:reload, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def loaded, do: false

  def init(_path), do: :erlang.nif_error(:nif_not_loaded)
  def open(_path, _ceiling), do: :erlang.nif_error(:nif_not_loaded)
  def status(_repo), do: :erlang.nif_error(:nif_not_loaded)
  def diff(_repo, _mode, _from, _to), do: :erlang.nif_error(:nif_not_loaded)
  def add(_repo, _paths), do: :erlang.nif_error(:nif_not_loaded)
  def reset(_repo, _type, _target, _paths), do: :erlang.nif_error(:nif_not_loaded)
  def commit(_repo, _message, _name, _email), do: :erlang.nif_error(:nif_not_loaded)
  def log(_repo, _limit), do: :erlang.nif_error(:nif_not_loaded)
  def branches(_repo), do: :erlang.nif_error(:nif_not_loaded)
  def create_branch(_repo, _name, _force), do: :erlang.nif_error(:nif_not_loaded)
  def checkout(_repo, _name, _force), do: :erlang.nif_error(:nif_not_loaded)
  def clone(_url, _path, _auth), do: :erlang.nif_error(:nif_not_loaded)
  def fetch(_repo, _remote, _auth), do: :erlang.nif_error(:nif_not_loaded)
  def pull(_repo, _remote, _auth), do: :erlang.nif_error(:nif_not_loaded)
  def push(_repo, _remote, _auth), do: :erlang.nif_error(:nif_not_loaded)
  def remotes(_repo), do: :erlang.nif_error(:nif_not_loaded)
  def remote_add(_repo, _name, _url), do: :erlang.nif_error(:nif_not_loaded)
  def remote_set_url(_repo, _name, _url), do: :erlang.nif_error(:nif_not_loaded)
  def workdir(_repo), do: :erlang.nif_error(:nif_not_loaded)

  defp priv_dir do
    case :code.priv_dir(:ex_git) do
      {:error, _} -> fallback_priv()
      dir -> dir
    end
  end

  # Desktop Mix: _build/.../lib/ex_git/ebin/*.beam → ../priv
  # Flattened iOS beams: priv next to the beam file.
  defp fallback_priv do
    case :code.which(__MODULE__) do
      :non_existing ->
        ~c"priv"

      path when is_list(path) ->
        beam_dir = path |> List.to_string() |> Path.dirname()

        cond do
          Path.basename(beam_dir) == "ebin" ->
            Path.join(Path.dirname(beam_dir), "priv")

          File.dir?(Path.join(beam_dir, "priv")) ->
            Path.join(beam_dir, "priv")

          true ->
            Path.join(Path.dirname(beam_dir), "priv")
        end
        |> String.to_charlist()
    end
  end
end
