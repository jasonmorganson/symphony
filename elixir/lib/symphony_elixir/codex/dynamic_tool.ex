defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Dispatches client-side tool calls to the configured tracker adapter.
  """

  alias SymphonyElixir.{MergeWriterTool, Tracker}

  @spec execute(String.t() | nil, term(), map(), keyword()) :: map()
  def execute(tool, arguments, binding, opts \\ []) do
    if tool == MergeWriterTool.tool_name() do
      MergeWriterTool.execute(arguments, opts)
    else
      Tracker.execute_bound_agent_tool(binding, tool, arguments, opts)
    end
  end

  @spec bind() :: map()
  def bind do
    binding = Tracker.bind_agent_tools()
    %{binding | tool_specs: binding.tool_specs ++ [MergeWriterTool.tool_spec()]}
  end
end
