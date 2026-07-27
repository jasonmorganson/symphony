defmodule SymphonyElixir.MergeWriterTool do
  @moduledoc """
  Exposes the orchestrator-owned final merge-writer lease to active agents.
  """

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Tracker.Issue

  @tool_name "symphony_merge_writer"

  @spec tool_spec() :: map()
  def tool_spec do
    %{
      "name" => @tool_name,
      "description" =>
        "Acquire or release Symphony's singleton final merge-writer lease, or yield the active agent after this turn. Acquire immediately before the irreversible final merge write; release after landing.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => ["acquire", "release", "yield"]}
        },
        "required" => ["action"],
        "additionalProperties" => false
      }
    }
  end

  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @spec execute(term(), keyword()) :: map()
  def execute(arguments, opts) do
    issue = Keyword.fetch!(opts, :issue)
    server = Keyword.get(opts, :merge_writer_server, Orchestrator)

    case {normalize_action(arguments), issue} do
      {{:ok, :acquire}, %Issue{} = issue} ->
        respond(Orchestrator.acquire_merge_writer(server, issue))

      {{:ok, :release}, %Issue{} = issue} ->
        respond(Orchestrator.release_merge_writer(server, issue))

      {{:ok, :yield}, %Issue{} = issue} ->
        request_yield(server, issue)

      {{:error, reason}, _issue} ->
        respond({:error, reason})

      {_action, _issue} ->
        respond({:error, :missing_issue_context})
    end
  end

  defp normalize_action(%{"action" => "acquire"}), do: {:ok, :acquire}
  defp normalize_action(%{"action" => "release"}), do: {:ok, :release}
  defp normalize_action(%{"action" => "yield"}), do: {:ok, :yield}
  defp normalize_action(_arguments), do: {:error, :invalid_action}

  defp request_yield(server, issue) do
    case Orchestrator.release_merge_writer(server, issue) do
      {:ok, release} ->
        Process.put(:symphony_yield_after_turn, true)
        respond({:ok, Map.put(release, :yield_after_turn, true)})

      {:error, reason} ->
        respond({:error, reason})
    end
  end

  @doc false
  @spec take_yield_request() :: boolean()
  def take_yield_request do
    Process.delete(:symphony_yield_after_turn) == true
  end

  defp respond({:ok, payload}), do: response(true, payload)
  defp respond({:error, reason}), do: response(false, %{error: inspect(reason)})

  defp response(success, payload) do
    output = Jason.encode!(payload)

    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end
end
