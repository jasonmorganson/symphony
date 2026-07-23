defmodule SymphonyElixir.Linear.RateLimit do
  @moduledoc """
  Shares Linear API cooldown state across pollers, retries, and agent tools.
  """

  use GenServer

  @type error :: {:linear_rate_limited, non_neg_integer()}
  @type telemetry :: %{
          optional(:requests) => map(),
          optional(:endpoint) => map(),
          optional(:complexity) => map(),
          required(:observed_at) => DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec check(GenServer.server()) :: :ok | {:error, error()}
  def check(server \\ __MODULE__) do
    if available?(server) do
      GenServer.call(server, :check)
    else
      :ok
    end
  end

  @spec activate(non_neg_integer(), GenServer.server()) :: :ok
  def activate(retry_after_ms, server \\ __MODULE__)
      when is_integer(retry_after_ms) and retry_after_ms >= 0 do
    if available?(server) do
      GenServer.call(server, {:activate, retry_after_ms})
    else
      :ok
    end
  end

  @spec observe(map() | list(), GenServer.server()) :: :ok
  def observe(headers, server \\ __MODULE__) when is_map(headers) or is_list(headers) do
    case rate_limit_telemetry(headers) do
      nil ->
        :ok

      telemetry ->
        if available?(server), do: GenServer.cast(server, {:observe, telemetry})
        :ok
    end
  end

  @spec snapshot(GenServer.server()) :: telemetry() | nil
  def snapshot(server \\ __MODULE__) do
    if available?(server) do
      GenServer.call(server, :snapshot)
    end
  end

  @doc false
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__) do
    if available?(server) do
      GenServer.call(server, :reset)
    else
      :ok
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{cooldown_until_ms: nil, telemetry: nil}}
  end

  @impl true
  def handle_call(:check, _from, %{cooldown_until_ms: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:check, _from, state) do
    remaining_ms = max(state.cooldown_until_ms - now_ms(), 0)

    if remaining_ms > 0 do
      {:reply, {:error, {:linear_rate_limited, remaining_ms}}, state}
    else
      {:reply, :ok, %{state | cooldown_until_ms: nil}}
    end
  end

  def handle_call({:activate, retry_after_ms}, _from, state) do
    cooldown_until_ms = max(state.cooldown_until_ms || now_ms(), now_ms() + retry_after_ms)
    {:reply, :ok, %{state | cooldown_until_ms: cooldown_until_ms}}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, state.telemetry, state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | cooldown_until_ms: nil, telemetry: nil}}
  end

  @impl true
  def handle_cast({:observe, telemetry}, state) do
    {:noreply, %{state | telemetry: telemetry}}
  end

  defp rate_limit_telemetry(headers) do
    telemetry =
      %{}
      |> maybe_put_quota(:requests, headers, %{
        limit: "x-ratelimit-requests-limit",
        remaining: "x-ratelimit-requests-remaining",
        reset_at_ms: "x-ratelimit-requests-reset"
      })
      |> maybe_put_quota(:endpoint, headers, %{
        name: "x-ratelimit-endpoint-name",
        limit: "x-ratelimit-endpoint-requests-limit",
        remaining: "x-ratelimit-endpoint-requests-remaining",
        reset_at_ms: "x-ratelimit-endpoint-requests-reset"
      })
      |> maybe_put_quota(:complexity, headers, %{
        query: "x-complexity",
        limit: "x-ratelimit-complexity-limit",
        remaining: "x-ratelimit-complexity-remaining",
        reset_at_ms: "x-ratelimit-complexity-reset"
      })

    if map_size(telemetry) == 0 do
      nil
    else
      Map.put(telemetry, :observed_at, DateTime.utc_now())
    end
  end

  @spec header_value(map() | list(), String.t()) :: String.t() | integer() | nil
  def header_value(headers, name)
      when (is_map(headers) or is_list(headers)) and is_binary(name) do
    Enum.find_value(headers, fn
      {header_name, [value | _]}
      when is_binary(header_name) and (is_binary(value) or is_integer(value)) ->
        if String.downcase(header_name) == name, do: value

      {header_name, value}
      when is_binary(header_name) and (is_binary(value) or is_integer(value)) ->
        if String.downcase(header_name) == name, do: value

      _ ->
        nil
    end)
  end

  defp maybe_put_quota(telemetry, key, headers, fields) do
    quota =
      fields
      |> Enum.reduce(%{}, fn {field, header}, acc ->
        case telemetry_value(header_value(headers, header), field) do
          nil -> acc
          value -> Map.put(acc, field, value)
        end
      end)

    if map_size(quota) == 0, do: telemetry, else: Map.put(telemetry, key, quota)
  end

  defp telemetry_value(value, :name) when is_binary(value), do: value

  defp telemetry_value(value, _field) when is_integer(value), do: value

  defp telemetry_value(value, _field) when is_binary(value) do
    case value |> String.trim() |> String.replace(",", "") |> Integer.parse() do
      {number, ""} when number >= 0 -> number
      _ -> nil
    end
  end

  defp telemetry_value(_value, _field), do: nil

  defp available?(server) when is_pid(server), do: Process.alive?(server)
  defp available?(server) when is_atom(server), do: is_pid(Process.whereis(server))
  defp available?(_server), do: false

  defp now_ms, do: System.monotonic_time(:millisecond)
end
