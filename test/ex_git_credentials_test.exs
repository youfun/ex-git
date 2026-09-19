defmodule ExGit.CredentialsTest do
  use ExUnit.Case, async: true

  setup context do
    dir = Path.join(System.tmp_dir!(), "ex_git_auth_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)

    redirect =
      if context[:redirect],
        do: "http://localhost:#{port}/other.git/info/refs?service=git-upload-pack"

    server = Task.async(fn -> requests(listener, [], redirect) end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm_rf!(dir)
    end)

    {:ok,
     dir: dir,
     listener: listener,
     server: server,
     url: "http://127.0.0.1:#{port}/repo.git",
     origin: "http://127.0.0.1:#{port}"}
  end

  test "sends credentials to the configured authentication endpoint", ctx do
    assert {:error, _} =
             ExGit.clone(ctx.url, Path.join(ctx.dir, "clone"),
               password: "review-fixture",
               credential_endpoint: ctx.origin
             )

    :gen_tcp.close(ctx.listener)
    headers = Task.await(ctx.server)
    expected = "Authorization: Basic " <> Base.encode64("x-access-token:review-fixture")
    assert Enum.any?(headers, &String.contains?(&1, expected))
  end

  test "rejects fresh authentication at a port outside the configured endpoint", ctx do
    assert {:error, {_, message}} =
             ExGit.clone(ctx.url, Path.join(ctx.dir, "clone"),
               password: "review-fixture",
               credential_endpoint: "http://127.0.0.1"
             )

    assert message =~ "credential endpoint mismatch"
    :gen_tcp.close(ctx.listener)
    headers = Task.await(ctx.server)
    assert headers != []
    refute Enum.any?(headers, &String.contains?(String.downcase(&1), "authorization:"))
  end

  @tag redirect: true
  test "does not forward previously accepted credentials through off-site redirects", ctx do
    assert {:error, _} =
             ExGit.clone(ctx.url, Path.join(ctx.dir, "clone"),
               password: "review-fixture",
               credential_endpoint: ctx.origin
             )

    :gen_tcp.close(ctx.listener)
    headers = Task.await(ctx.server)
    assert Enum.any?(headers, &String.contains?(String.downcase(&1), "authorization:"))
    assert Enum.all?(headers, &String.starts_with?(&1, "GET /repo.git/")), inspect(headers)
  end

  test "characterizes libgit2 same-host credential replay across ports", ctx do
    # Upstream behavior, not a desired isolation guarantee. If libgit2 tightens
    # redirects, revise this characterization and the documented trust boundary.
    {:ok, source} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(source)
    redirect = ctx.url <> "/info/refs?service=git-upload-pack"
    server = Task.async(fn -> requests(source, [], redirect) end)
    on_exit(fn -> :gen_tcp.close(source) end)
    origin = "http://127.0.0.1:#{port}"

    assert {:error, _} =
             ExGit.clone(origin <> "/repo.git", Path.join(ctx.dir, "clone"),
               password: "review-fixture",
               credential_endpoint: origin
             )

    :gen_tcp.close(source)
    headers = Task.await(server)
    assert Enum.any?(headers, &String.contains?(String.downcase(&1), "authorization:"))
    :gen_tcp.close(ctx.listener)
    forwarded = Task.await(ctx.server)
    expected = "Authorization: Basic " <> Base.encode64("x-access-token:review-fixture")
    assert Enum.any?(forwarded, &String.contains?(&1, expected))
  end

  test "checks the effective push URL, not just the remote fetch URL", ctx do
    path = Path.join(ctx.dir, "local")
    {:ok, repo} = ExGit.init(path)
    File.write!(Path.join(path, "file.txt"), "fixture")
    :ok = ExGit.add(repo, [])
    {:ok, _} = ExGit.commit(repo, "fixture", name: "Test", email: "test@example.com")
    allowed = "http://example.invalid"
    :ok = ExGit.remote_add(repo, "origin", allowed)

    File.write!(
      Path.join(path, ".git/config"),
      "\n[remote \"origin\"]\n\tpushurl = #{ctx.url}\n",
      [:append]
    )

    assert {:error, {_, message}} =
             ExGit.push(repo, password: "review-fixture", credential_endpoint: allowed)

    assert message =~ "credential endpoint mismatch"
    :gen_tcp.close(ctx.listener)
    headers = Task.await(ctx.server)
    refute Enum.any?(headers, &String.contains?(String.downcase(&1), "authorization:"))
  end

  defp requests(listener, acc, redirect) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        request = headers(socket, "")

        status =
          cond do
            not String.contains?(String.downcase(request), "authorization:") -> "401 Unauthorized"
            is_binary(redirect) and String.starts_with?(request, "GET /repo.git/") -> "302 Found"
            true -> "403 Forbidden"
          end

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 #{status}\r\nLocation: #{redirect}\r\nWWW-Authenticate: Basic realm=\"test\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          )

        :gen_tcp.close(socket)
        requests(listener, [request | acc], redirect)

      {:error, :closed} ->
        Enum.reverse(acc)
    end
  end

  defp headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, "\r\n"} -> acc
      {:ok, line} -> headers(socket, acc <> line)
    end
  end
end
