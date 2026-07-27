defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Orchestrator, Tracker}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    payload =
      orchestrator()
      |> Presenter.state_payload(snapshot_timeout_ms())
      |> maybe_put_tracker_rate_limits()

    json(conn, payload)
  end

  defp maybe_put_tracker_rate_limits(%{error: _error} = payload), do: payload

  defp maybe_put_tracker_rate_limits(payload) do
    Map.put(payload, :tracker_rate_limits, Tracker.rate_limit_snapshot())
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec operator_resume(Conn.t(), map()) :: Conn.t()
  def operator_resume(
        conn,
        %{"issue_identifiers" => identifiers, "reason" => reason}
      )
      when is_list(identifiers) and is_binary(reason) do
    with true <- operator_action_authorized?(conn),
         {:ok, normalized_identifiers} <- normalize_resume_identifiers(identifiers),
         {:ok, normalized_reason} <- normalize_resume_reason(reason),
         {:ok, human_review_issues} <- Tracker.fetch_issues_by_states(["Human Review"]),
         {:ok, selected_issues} <-
           select_resume_issues(human_review_issues, normalized_identifiers),
         {:ok, payload} <-
           Orchestrator.resume_issues(
             orchestrator(),
             selected_issues,
             normalized_reason,
             snapshot_timeout_ms()
           ) do
      conn
      |> put_status(202)
      |> json(payload)
    else
      false ->
        error_response(conn, 401, "unauthorized", "Valid operator authorization is required")

      {:error, :invalid_issue_identifiers} ->
        error_response(
          conn,
          422,
          "invalid_issue_identifiers",
          "issue_identifiers must contain 1 to 10 unique tracker identifiers"
        )

      {:error, :invalid_reason} ->
        error_response(conn, 422, "invalid_reason", "reason must contain 1 to 500 characters")

      {:error, {:issues_not_in_human_review, _missing}} ->
        error_response(
          conn,
          409,
          "issues_not_in_human_review",
          "Every requested issue must currently be in Human Review"
        )

      {:error, _reason} ->
        error_response(conn, 503, "operator_resume_unavailable", "Operator resume is unavailable")
    end
  end

  def operator_resume(conn, _params) do
    error_response(
      conn,
      422,
      "invalid_operator_resume",
      "issue_identifiers and reason are required"
    )
  end

  @spec worker_drains(Conn.t(), map()) :: Conn.t()
  def worker_drains(conn, %{"drained_worker_hosts" => hosts}) when is_list(hosts) do
    if operator_action_authorized?(conn) do
      if Enum.all?(hosts, &is_binary/1) do
        worker_drains_response(conn, Presenter.worker_drains_payload(orchestrator(), hosts))
      else
        error_response(conn, 422, "invalid_worker_hosts", "drained_worker_hosts must contain only strings")
      end
    else
      error_response(conn, 401, "unauthorized", "Valid worker drain authorization is required")
    end
  end

  def worker_drains(conn, _params) do
    error_response(conn, 422, "invalid_worker_hosts", "drained_worker_hosts must be a list")
  end

  defp worker_drains_response(conn, result) do
    case result do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :timeout} ->
        error_response(conn, 503, "orchestrator_timeout", "Orchestrator drain update timed out")

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")

      {:error, {:unknown_worker_hosts, invalid_hosts}} ->
        _ = invalid_hosts
        error_response(conn, 422, "unknown_worker_hosts", "Request includes unknown or invalid worker hosts")

      {:error, {:drain_state_write_failed, _reason}} ->
        error_response(conn, 503, "drain_state_write_failed", "Worker drain state could not be persisted")
    end
  end

  defp operator_action_authorized?(conn) do
    expected = Endpoint.config(:worker_drain_token) || System.get_env("SYMPHONY_WORKER_DRAIN_TOKEN")

    with expected when is_binary(expected) and byte_size(expected) >= 32 <- expected,
         ["Bearer " <> supplied] <- get_req_header(conn, "authorization"),
         true <- byte_size(supplied) == byte_size(expected) do
      Plug.Crypto.secure_compare(supplied, expected)
    else
      _ -> false
    end
  end

  defp normalize_resume_identifiers(identifiers) do
    normalized =
      identifiers
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if length(normalized) in 1..10 and
         length(normalized) == length(identifiers) and
         Enum.all?(normalized, &Regex.match?(~r/^[A-Za-z][A-Za-z0-9_-]*-\d+$/, &1)) do
      {:ok, normalized}
    else
      {:error, :invalid_issue_identifiers}
    end
  end

  defp normalize_resume_reason(reason) do
    normalized = String.trim(reason)

    if byte_size(normalized) in 1..500 do
      {:ok, normalized}
    else
      {:error, :invalid_reason}
    end
  end

  defp select_resume_issues(issues, identifiers) do
    issue_by_identifier = Map.new(issues, &{&1.identifier, &1})
    selected = Enum.map(identifiers, &Map.get(issue_by_identifier, &1))

    if Enum.all?(selected, &match?(%SymphonyElixir.Tracker.Issue{}, &1)) do
      {:ok, selected}
    else
      missing =
        identifiers
        |> Enum.zip(selected)
        |> Enum.filter(fn {_identifier, issue} -> is_nil(issue) end)
        |> Enum.map(&elem(&1, 0))

      {:error, {:issues_not_in_human_review, missing}}
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
