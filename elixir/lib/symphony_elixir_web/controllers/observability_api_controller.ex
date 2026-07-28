defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Config, Tracker}
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
    cond do
      !worker_drain_authorized?(conn) ->
        error_response(conn, 401, "unauthorized", "Valid worker drain authorization is required")

      !Enum.all?(hosts, &is_binary/1) ->
        error_response(
          conn,
          422,
          "invalid_worker_hosts",
          "drained_worker_hosts must contain only strings"
        )

      true ->
        worker_drains_response(conn, Presenter.worker_drains_payload(orchestrator(), hosts))
    end
  end

  def worker_drains(conn, _params) do
    error_response(conn, 422, "invalid_worker_hosts", "drained_worker_hosts must be a list")
  end

  @spec workspace_reclamation(Conn.t(), map()) :: Conn.t()
  def workspace_reclamation(conn, %{"issue_identifiers" => identifiers})
      when is_list(identifiers) do
    cond do
      !worker_drain_authorized?(conn) ->
        error_response(conn, 401, "unauthorized", "Valid control authorization is required")

      length(identifiers) > 50 or
          !Enum.all?(identifiers, &(is_binary(&1) and byte_size(&1) > 0)) ->
        error_response(
          conn,
          422,
          "invalid_issue_identifiers",
          "issue_identifiers must contain at most 50 non-empty strings"
        )

      true ->
        workspace_reclamation_response(conn, Tracker.fetch_issues_by_ids(Enum.uniq(identifiers)))
    end
  end

  def workspace_reclamation(conn, _params) do
    error_response(conn, 422, "invalid_issue_identifiers", "issue_identifiers must be a list")
  end

  defp worker_drains_response(conn, {:ok, payload}), do: json(conn, payload)

  defp worker_drains_response(conn, {:error, :timeout}) do
    error_response(conn, 503, "orchestrator_timeout", "Orchestrator drain update timed out")
  end

  defp worker_drains_response(conn, {:error, :unavailable}) do
    error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
  end

  defp worker_drains_response(conn, {:error, {:unknown_worker_hosts, _invalid_hosts}}) do
    error_response(
      conn,
      422,
      "unknown_worker_hosts",
      "Request includes unknown or invalid worker hosts"
    )
  end

  defp worker_drains_response(conn, {:error, {:drain_state_write_failed, _reason}}) do
    error_response(conn, 503, "drain_state_write_failed", "Worker drain state could not be persisted")
  end

  defp workspace_reclamation_response(conn, {:ok, issues}) do
    terminal_states = MapSet.new(Config.settings!().tracker.terminal_states)

    json(conn, %{
      issues:
        Enum.map(issues, fn issue ->
          terminal = MapSet.member?(terminal_states, issue.state)

          %{
            issue_identifier: issue.identifier,
            terminal: terminal,
            terminal_at: if(terminal, do: iso8601(issue.updated_at), else: nil)
          }
        end)
    })
  end

  defp workspace_reclamation_response(conn, {:error, _reason}) do
    error_response(conn, 503, "tracker_unavailable", "Tracker state could not be read")
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

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_value), do: nil
end
