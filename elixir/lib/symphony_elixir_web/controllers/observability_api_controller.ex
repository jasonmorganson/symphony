defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
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

  @spec worker_drains(Conn.t(), map()) :: Conn.t()
  def worker_drains(conn, %{"drained_worker_hosts" => hosts}) when is_list(hosts) do
    if worker_drain_authorized?(conn) do
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

  defp worker_drain_authorized?(conn) do
    expected = Endpoint.config(:worker_drain_token) || System.get_env("SYMPHONY_WORKER_DRAIN_TOKEN")

    with expected when is_binary(expected) and byte_size(expected) >= 32 <- expected,
         ["Bearer " <> supplied] <- get_req_header(conn, "authorization"),
         true <- byte_size(supplied) == byte_size(expected) do
      Plug.Crypto.secure_compare(supplied, expected)
    else
      _ -> false
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
