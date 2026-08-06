defmodule SymphonyElixir.Codex.TaskSettings do
  @moduledoc false

  alias SymphonyElixir.Config.Schema.Codex
  alias SymphonyElixir.Tracker.Issue

  @type t :: %{
          model: String.t() | nil,
          reasoning_effort: String.t() | nil,
          fingerprint: [String.t()],
          overridden?: boolean()
        }

  @spec resolve(Issue.t(), Codex.t()) :: {:ok, t()} | {:error, term()}
  def resolve(%Issue{labels: labels}, %Codex{} = defaults) when is_list(labels) do
    with {:ok, model} <- label_value(labels, :model),
         {:ok, reasoning_effort} <- label_value(labels, :reasoning) do
      {:ok,
       %{
         model: model || defaults.model,
         reasoning_effort: reasoning_effort || defaults.reasoning_effort,
         fingerprint: fingerprint_from_labels(labels),
         overridden?: not is_nil(model) or not is_nil(reasoning_effort)
       }}
    end
  end

  def resolve(%Issue{}, %Codex{}), do: {:error, {:invalid_task_codex_settings, :labels, :invalid}}

  @spec configuration_error?(term()) :: boolean()
  def configuration_error?({:task_configuration_error, _}), do: true
  def configuration_error?({:invalid_task_codex_settings, _, _}), do: true
  def configuration_error?(_), do: false

  @spec fingerprint(Issue.t()) :: [String.t()]
  def fingerprint(%Issue{labels: labels}) when is_list(labels), do: fingerprint_from_labels(labels)
  def fingerprint(%Issue{}), do: []

  @spec format_error(term()) :: String.t()
  def format_error({:invalid_task_codex_settings, setting, :empty}) do
    "task label #{setting}: must include a value"
  end

  def format_error({:invalid_task_codex_settings, setting, {:conflicting, values}}) do
    "task labels #{setting}: conflict: #{Enum.join(values, ", ")}"
  end

  def format_error({:task_configuration_error, reason}) do
    "Codex rejected the task model or reasoning configuration: #{inspect(reason)}"
  end

  def format_error(reason), do: "invalid task Codex configuration: #{inspect(reason)}"

  defp label_value(labels, setting) when setting in [:model, :reasoning] do
    prefix = Atom.to_string(setting) <> ":"

    values =
      labels
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.map(&String.trim(String.replace_prefix(&1, prefix, "")))

    if Enum.any?(values, &(&1 == "")) do
      {:error, {:invalid_task_codex_settings, setting, :empty}}
    else
      case Enum.uniq(values) do
        [] -> {:ok, nil}
        [value] -> {:ok, value}
        conflicting -> {:error, {:invalid_task_codex_settings, setting, {:conflicting, conflicting}}}
      end
    end
  end

  defp fingerprint_from_labels(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(String.starts_with?(&1, "model:") or String.starts_with?(&1, "reasoning:")))
    |> Enum.sort()
  end
end
