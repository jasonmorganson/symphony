defmodule SymphonyElixir.WorkerAffinityStore do
  @moduledoc """
  Atomically persists the worker that owns each issue's durable workspace.

  An issue must keep using its recorded worker until terminal cleanup removes
  the affinity. This prevents an orchestrator restart from selecting a stale
  copy of the same workspace on another worker.
  """

  @version 1

  @spec load(Path.t() | nil, [String.t()]) ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, term()}
  def load(path, configured_hosts), do: load(path, nil, configured_hosts)

  @spec load(Path.t() | nil, Path.t() | nil, [String.t()]) ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, term()}
  def load(nil, _seed_path, _configured_hosts), do: {:ok, %{}}

  def load(path, seed_path, configured_hosts)
      when is_binary(path) and is_list(configured_hosts) do
    case File.read(path) do
      {:ok, contents} -> decode(contents, configured_hosts)
      {:error, :enoent} -> load_seed(path, seed_path, configured_hosts)
      {:error, reason} -> {:error, {:affinity_state_read_failed, reason}}
    end
  end

  @spec put(Path.t() | nil, map(), String.t(), String.t(), [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def put(path, affinities, issue_id, worker_host, configured_hosts)
      when is_map(affinities) and is_binary(issue_id) and is_binary(worker_host) do
    with :ok <- validate_host_owner(affinities, issue_id, worker_host),
         updated = Map.put(affinities, issue_id, worker_host),
         :ok <- validate(updated, configured_hosts),
         :ok <- persist(path, updated) do
      {:ok, updated}
    end
  end

  @spec delete(Path.t() | nil, map(), String.t(), [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def delete(path, affinities, issue_id, configured_hosts)
      when is_map(affinities) and is_binary(issue_id) do
    updated = Map.delete(affinities, issue_id)

    with :ok <- validate(updated, configured_hosts),
         :ok <- persist(path, updated) do
      {:ok, updated}
    end
  end

  @spec persist(Path.t() | nil, map()) :: :ok | {:error, term()}
  def persist(nil, _affinities), do: :ok

  def persist(path, affinities) when is_binary(path) and is_map(affinities) do
    directory = Path.dirname(path)
    temporary = path <> ".tmp"
    payload = Jason.encode!(%{version: @version, affinities: affinities})

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(temporary, payload, [:sync]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, {:affinity_state_write_failed, reason}}
    end
  end

  defp decode(contents, configured_hosts) do
    with {:ok, %{"version" => @version, "affinities" => affinities}} when is_map(affinities) <-
           Jason.decode(contents),
         :ok <- validate(affinities, configured_hosts) do
      {:ok, affinities}
    else
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:invalid_affinity_state, reason}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_affinity_state}
    end
  end

  defp load_seed(_path, nil, _configured_hosts), do: {:ok, %{}}

  defp load_seed(path, seed_path, configured_hosts) when is_binary(seed_path) do
    with {:ok, contents} <- File.read(seed_path),
         {:ok, affinities} <- decode(contents, configured_hosts),
         :ok <- persist(path, affinities) do
      {:ok, affinities}
    else
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, {:affinity_seed_failed, reason}}
    end
  end

  defp validate(affinities, configured_hosts) when is_map(affinities) do
    valid_hosts = MapSet.new(configured_hosts)

    if Enum.all?(affinities, fn {issue_id, worker_host} ->
         is_binary(issue_id) and issue_id != "" and is_binary(worker_host) and worker_host != "" and
           MapSet.member?(valid_hosts, worker_host)
       end) do
      :ok
    else
      {:error, :invalid_affinity_state}
    end
  end

  defp validate_host_owner(affinities, issue_id, worker_host) do
    case Enum.find(affinities, fn {other_issue_id, host} ->
           other_issue_id != issue_id and host == worker_host
         end) do
      nil -> :ok
      {other_issue_id, _host} -> {:error, {:worker_affinity_owned, worker_host, other_issue_id}}
    end
  end
end
