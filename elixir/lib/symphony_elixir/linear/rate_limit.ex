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
          optional(:admission) => map(),
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
      GenServer.call(server, :check, :infinity)
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

  @doc """
  Spreads orchestration polls across the latest reported request quota window.

  The request budget should include the expected number of tracker requests in
  one poll cycle. When telemetry is unavailable or incomplete, the configured
  interval is returned unchanged.
  """
  @spec recommended_poll_delay(non_neg_integer(), pos_integer(), GenServer.server()) ::
          non_neg_integer()
  def recommended_poll_delay(base_delay_ms, request_budget \\ 1, server \\ __MODULE__)
      when is_integer(base_delay_ms) and base_delay_ms >= 0 and is_integer(request_budget) and
             request_budget > 0 do
    telemetry = snapshot(server)
    recommended_poll_delay_for_telemetry(telemetry, base_delay_ms, request_budget, system_now_ms())
  end

  @doc false
  @spec recommended_poll_delay_for_test(map() | nil, non_neg_integer(), pos_integer(), integer()) ::
          non_neg_integer()
  def recommended_poll_delay_for_test(telemetry, base_delay_ms, request_budget, now_ms)
      when is_integer(base_delay_ms) and base_delay_ms >= 0 and is_integer(request_budget) and
             request_budget > 0 and is_integer(now_ms) do
    recommended_poll_delay_for_telemetry(telemetry, base_delay_ms, request_budget, now_ms)
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
  def init(opts) do
    {:ok,
     %{
       cooldown_until_ms: nil,
       deferred_requests: 0,
       monotonic_now_fun: Keyword.get(opts, :monotonic_now_fun, fn -> System.monotonic_time(:millisecond) end),
       next_request_at_ms: nil,
       pacing_timer_ref: nil,
       system_now_fun: Keyword.get(opts, :system_now_fun, fn -> System.system_time(:millisecond) end),
       telemetry: nil,
       waiters: :queue.new()
     }}
  end

  @impl true
  def handle_call(:check, from, state) do
    monotonic_now_ms = state.monotonic_now_fun.()

    cooldown_remaining_ms =
      max((state.cooldown_until_ms || monotonic_now_ms) - monotonic_now_ms, 0)

    pacing_remaining_ms =
      max((state.next_request_at_ms || monotonic_now_ms) - monotonic_now_ms, 0)

    reserve_remaining_ms =
      reserve_cooldown_remaining(state.telemetry, state.system_now_fun.())

    cond do
      cooldown_remaining_ms > 0 ->
        state = Map.update!(state, :deferred_requests, &(&1 + 1))
        {:reply, {:error, {:linear_rate_limited, cooldown_remaining_ms}}, state}

      reserve_remaining_ms > 0 ->
        state = Map.update!(state, :deferred_requests, &(&1 + 1))
        {:reply, {:error, {:linear_rate_limited, reserve_remaining_ms}}, state}

      :queue.is_empty(state.waiters) and pacing_remaining_ms == 0 ->
        {:reply, :ok, admit_request(state, monotonic_now_ms)}

      true ->
        waiters = :queue.in(from, state.waiters)

        state =
          state
          |> Map.put(:waiters, waiters)
          |> Map.update!(:deferred_requests, &(&1 + 1))
          |> schedule_pacing_timer(pacing_remaining_ms)

        {:noreply, state}
    end
  end

  def handle_call({:activate, retry_after_ms}, _from, state) do
    monotonic_now_ms = state.monotonic_now_fun.()

    cooldown_until_ms =
      max(state.cooldown_until_ms || monotonic_now_ms, monotonic_now_ms + retry_after_ms)

    remaining_ms = max(cooldown_until_ms - monotonic_now_ms, 0)

    state =
      state
      |> flush_waiters({:error, {:linear_rate_limited, remaining_ms}})
      |> Map.put(:cooldown_until_ms, cooldown_until_ms)

    {:reply, :ok, state}
  end

  def handle_call(:snapshot, _from, state) do
    monotonic_now_ms = state.monotonic_now_fun.()

    telemetry =
      if is_map(state.telemetry) do
        Map.put(state.telemetry, :admission, %{
          deferred_requests: state.deferred_requests,
          next_request_in_ms: max((state.next_request_at_ms || monotonic_now_ms) - monotonic_now_ms, 0),
          queued_requests: :queue.len(state.waiters)
        })
      end

    {:reply, telemetry, state}
  end

  def handle_call(:reset, _from, state) do
    state = flush_waiters(state, :ok)

    {:reply, :ok,
     %{
       state
       | cooldown_until_ms: nil,
         deferred_requests: 0,
         next_request_at_ms: nil,
         telemetry: nil
     }}
  end

  @impl true
  def handle_cast({:observe, telemetry}, state) do
    {:noreply, %{state | telemetry: telemetry}}
  end

  @impl true
  def handle_info(
        {:release_waiter, token},
        %{pacing_timer_ref: {_timer_ref, token}} = state
      ) do
    state = %{state | pacing_timer_ref: nil}
    monotonic_now_ms = state.monotonic_now_fun.()

    reserve_remaining_ms =
      reserve_cooldown_remaining(state.telemetry, state.system_now_fun.())

    pacing_remaining_ms =
      max((state.next_request_at_ms || monotonic_now_ms) - monotonic_now_ms, 0)

    cond do
      reserve_remaining_ms > 0 ->
        state =
          flush_waiters(
            state,
            {:error, {:linear_rate_limited, reserve_remaining_ms}}
          )

        {:noreply, state}

      pacing_remaining_ms > 0 ->
        {:noreply, schedule_pacing_timer(state, pacing_remaining_ms)}

      true ->
        release_next_waiter(state, monotonic_now_ms)
    end
  end

  def handle_info({:release_waiter, _token}, state), do: {:noreply, state}

  defp release_next_waiter(state, monotonic_now_ms) do
    {{:value, from}, waiters} = :queue.out(state.waiters)
    GenServer.reply(from, :ok)
    state = %{admit_request(state, monotonic_now_ms) | waiters: waiters}
    pacing_remaining_ms = max(state.next_request_at_ms - monotonic_now_ms, 0)
    {:noreply, schedule_pacing_timer(state, pacing_remaining_ms)}
  end

  defp admit_request(state, monotonic_now_ms) do
    pacing_delay_ms = request_pacing_delay(state.telemetry, state.system_now_fun.())

    %{
      state
      | cooldown_until_ms: nil,
        next_request_at_ms: monotonic_now_ms + pacing_delay_ms
    }
  end

  defp schedule_pacing_timer(%{pacing_timer_ref: {timer_ref, _token}} = state, _delay_ms)
       when is_reference(timer_ref),
       do: state

  defp schedule_pacing_timer(state, delay_ms) do
    if :queue.is_empty(state.waiters) do
      state
    else
      token = make_ref()
      timer_ref = Process.send_after(self(), {:release_waiter, token}, max(delay_ms, 0))
      %{state | pacing_timer_ref: {timer_ref, token}}
    end
  end

  defp flush_waiters(state, reply) do
    case state.pacing_timer_ref do
      {timer_ref, _token} when is_reference(timer_ref) -> Process.cancel_timer(timer_ref)
      _other -> :ok
    end

    state.waiters
    |> :queue.to_list()
    |> Enum.each(&GenServer.reply(&1, reply))

    %{state | pacing_timer_ref: nil, waiters: :queue.new()}
  end

  defp reserve_cooldown_remaining(
         %{requests: %{limit: limit, remaining: remaining, reset_at_ms: reset_at_ms}},
         now_ms
       )
       when is_integer(limit) and limit > 0 and is_integer(remaining) and remaining >= 0 and
              is_integer(reset_at_ms) do
    reserve = max(div(limit, 10), 100)

    if remaining <= reserve do
      max(reset_at_ms - now_ms, 0)
    else
      0
    end
  end

  defp reserve_cooldown_remaining(_telemetry, _now_ms), do: 0

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

  defp recommended_poll_delay_for_telemetry(
         %{requests: %{remaining: remaining, reset_at_ms: reset_at_ms}},
         base_delay_ms,
         request_budget,
         now_ms
       )
       when is_integer(remaining) and remaining >= 0 and is_integer(reset_at_ms) do
    window_ms = max(reset_at_ms - now_ms, 0)

    quota_delay_ms =
      if window_ms == 0 do
        0
      else
        ceil_div(window_ms * request_budget, max(remaining, 1))
      end

    max(base_delay_ms, quota_delay_ms)
  end

  defp recommended_poll_delay_for_telemetry(
         _telemetry,
         base_delay_ms,
         _request_budget,
         _now_ms
       ),
       do: base_delay_ms

  defp request_pacing_delay(
         %{requests: %{limit: limit, remaining: remaining, reset_at_ms: reset_at_ms}},
         now_ms
       )
       when is_integer(limit) and limit > 0 and is_integer(remaining) and remaining >= 0 and
              is_integer(reset_at_ms) do
    window_ms = max(reset_at_ms - now_ms, 0)
    reserve = max(div(limit, 10), 100)
    spendable_requests = max(remaining - reserve, 0)

    cond do
      window_ms == 0 -> 0
      spendable_requests == 0 -> window_ms
      true -> ceil_div(window_ms, spendable_requests)
    end
  end

  defp request_pacing_delay(_telemetry, _now_ms), do: 0

  defp ceil_div(dividend, divisor), do: div(dividend + divisor - 1, divisor)

  defp available?(server) when is_pid(server), do: Process.alive?(server)
  defp available?(server) when is_atom(server), do: is_pid(Process.whereis(server))
  defp available?(_server), do: false

  defp system_now_ms, do: System.system_time(:millisecond)
end
