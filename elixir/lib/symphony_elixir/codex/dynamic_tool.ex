defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Dispatches client-side tool calls to built-in Symphony tools or the
  configured tracker adapter.
  """

  alias SymphonyElixir.Tracker

  @outcome_tool_name "symphony_report_turn_outcome"
  @outcome_key {__MODULE__, :turn_outcome}
  @max_reason_length 500
  @outcome_tool_spec %{
    "name" => @outcome_tool_name,
    "description" => "Report whether Symphony should continue immediately or defer the next authoritative tracker recheck. This scheduling hint never changes tracker state.",
    "inputSchema" => %{
      "type" => "object",
      "properties" => %{
        "outcome" => %{
          "type" => "string",
          "enum" => ["continue", "defer"],
          "description" => "Continue immediately, or defer the next authoritative tracker recheck."
        },
        "reason" => %{
          "type" => "string",
          "maxLength" => @max_reason_length,
          "description" => "A concise scheduling reason. Do not name or request a tracker state."
        }
      },
      "required" => ["outcome"],
      "additionalProperties" => false
    }
  }

  @spec execute(String.t() | nil, term(), map(), keyword()) :: map()
  def execute(tool, arguments, binding, opts \\ []) do
    if tool == @outcome_tool_name do
      report_turn_outcome(arguments)
    else
      Tracker.execute_bound_agent_tool(binding, tool, arguments, opts)
    end
  end

  @spec bind() :: map()
  def bind do
    binding = Tracker.bind_agent_tools()

    if Enum.any?(binding.tool_specs, &(Map.get(&1, "name") == @outcome_tool_name)) do
      raise "tracker adapter tool collides with reserved built-in tool #{@outcome_tool_name}"
    end

    Map.update!(binding, :tool_specs, &[@outcome_tool_spec | &1])
  end

  @spec reset_turn_outcome() :: :ok
  def reset_turn_outcome do
    Process.delete(@outcome_key)
    :ok
  end

  @spec take_turn_outcome() :: %{outcome: :continue | :defer, reason: String.t() | nil} | nil
  def take_turn_outcome do
    Process.delete(@outcome_key)
  end

  defp report_turn_outcome(%{"outcome" => outcome} = arguments)
       when outcome in ["continue", "defer"] do
    with {:ok, reason} <- validate_reason(Map.get(arguments, "reason")),
         :ok <- reject_extra_arguments(arguments) do
      normalized = %{outcome: String.to_existing_atom(outcome), reason: reason}
      Process.put(@outcome_key, normalized)

      success_response(%{
        "outcome" => outcome,
        "reason" => reason,
        "effect" => "scheduling_hint_only"
      })
    else
      {:error, message} -> failure_response(message)
    end
  end

  defp report_turn_outcome(_arguments) do
    failure_response("`#{@outcome_tool_name}` requires an `outcome` of `continue` or `defer`.")
  end

  defp validate_reason(nil), do: {:ok, nil}

  defp validate_reason(reason) when is_binary(reason) do
    normalized = String.trim(reason)

    if String.length(normalized) <= @max_reason_length do
      {:ok, if(normalized == "", do: nil, else: normalized)}
    else
      {:error, "`reason` must be at most #{@max_reason_length} characters."}
    end
  end

  defp validate_reason(_reason), do: {:error, "`reason` must be a string when provided."}

  defp reject_extra_arguments(arguments) do
    case Map.keys(arguments) -- ["outcome", "reason"] do
      [] -> :ok
      _extra -> {:error, "`#{@outcome_tool_name}` received unsupported arguments."}
    end
  end

  defp success_response(payload) do
    output = Jason.encode!(payload)

    %{
      "success" => true,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp failure_response(message) do
    output = Jason.encode!(%{"error" => %{"message" => message}})

    %{
      "success" => false,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end
end
