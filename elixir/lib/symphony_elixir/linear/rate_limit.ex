defmodule SymphonyElixir.Linear.RateLimit do
  @moduledoc """
  Shares Linear API cooldown state across pollers, retries, and agent tools.
  """

  use GenServer

  @type error :: {:linear_rate_limited, non_neg_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec check(GenServer.server()) :: :ok | {:error, error()}
  def check(server \\ __MODULE__) do
    GenServer.call(server, :check)
  end

  @spec acquire(non_neg_integer(), GenServer.server()) :: :ok | {:error, error()}
  def acquire(request_interval_ms, server \\ __MODULE__)
      when is_integer(request_interval_ms) and request_interval_ms >= 0 do
    case GenServer.call(server, {:reserve, request_interval_ms}) do
      {:wait, wait_ms} ->
        Process.sleep(wait_ms)
        check(server)

      result ->
        result
    end
  end

  @spec activate(non_neg_integer(), GenServer.server()) :: :ok
  def activate(retry_after_ms, server \\ __MODULE__)
      when is_integer(retry_after_ms) and retry_after_ms >= 0 do
    GenServer.call(server, {:activate, retry_after_ms})
  end

  @impl true
  def init(_opts), do: {:ok, %{cooldown_until_ms: nil, next_request_at_ms: nil}}

  @impl true
  def handle_call(:check, _from, %{cooldown_until_ms: nil} = state), do: {:reply, :ok, state}

  def handle_call(:check, _from, state) do
    remaining_ms = max(state.cooldown_until_ms - now_ms(), 0)

    if remaining_ms > 0 do
      {:reply, {:error, {:linear_rate_limited, remaining_ms}}, state}
    else
      {:reply, :ok, %{state | cooldown_until_ms: nil}}
    end
  end

  def handle_call({:reserve, request_interval_ms}, _from, state) do
    now_ms = now_ms()
    remaining_ms = max((state.cooldown_until_ms || now_ms) - now_ms, 0)

    if remaining_ms > 0 do
      {:reply, {:error, {:linear_rate_limited, remaining_ms}}, state}
    else
      request_at_ms = max(state.next_request_at_ms || now_ms, now_ms)
      wait_ms = request_at_ms - now_ms

      {:reply, {:wait, wait_ms},
       %{
         state
         | cooldown_until_ms: nil,
           next_request_at_ms: request_at_ms + request_interval_ms
       }}
    end
  end

  def handle_call({:activate, retry_after_ms}, _from, state) do
    now_ms = now_ms()
    cooldown_until_ms = max(state.cooldown_until_ms || now_ms, now_ms + retry_after_ms)
    {:reply, :ok, %{state | cooldown_until_ms: cooldown_until_ms}}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
