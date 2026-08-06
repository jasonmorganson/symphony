defmodule SymphonyElixir.Codex.TaskSettingsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.TaskSettings
  alias SymphonyElixir.Config

  test "task labels inherit defaults and override model or reasoning independently" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_model: "gpt-5.6-terra",
      codex_reasoning_effort: "medium"
    )

    defaults = Config.settings!().codex

    assert {:ok, %{model: "gpt-5.6-terra", reasoning_effort: "medium", overridden?: false}} =
             TaskSettings.resolve(issue([]), defaults)

    assert {:ok, %{model: "gpt-5.6-terra", reasoning_effort: "medium", overridden?: true}} =
             TaskSettings.resolve(issue(["model:gpt-5.6-terra"]), defaults)

    assert {:ok, %{model: "gpt-5.6-terra", reasoning_effort: "high", overridden?: true}} =
             TaskSettings.resolve(issue(["reasoning:high"]), defaults)

    assert {:ok, %{model: "gpt-5.6-sol", reasoning_effort: "xhigh", overridden?: true}} =
             TaskSettings.resolve(issue([" model:gpt-5.6-sol ", " reasoning:xhigh "]), defaults)
  end

  test "task labels reject empty and conflicting Codex settings" do
    defaults = Config.settings!().codex

    assert {:error, {:invalid_task_codex_settings, :model, :empty}} =
             TaskSettings.resolve(issue(["model:  "]), defaults)

    assert {:error, {:invalid_task_codex_settings, :reasoning, :empty}} =
             TaskSettings.resolve(issue(["reasoning:"]), defaults)

    assert {:error, {:invalid_task_codex_settings, :model, {:conflicting, ["gpt-5.6-sol", "gpt-5.6-terra"]}}} =
             TaskSettings.resolve(issue(["model:gpt-5.6-sol", "model:gpt-5.6-terra"]), defaults)

    assert {:ok, %{model: "gpt-5.6-terra", overridden?: true}} =
             TaskSettings.resolve(issue(["model:gpt-5.6-terra", "model:gpt-5.6-terra"]), defaults)
  end

  test "task configuration fingerprints include only model and reasoning labels" do
    assert TaskSettings.fingerprint(issue(["backend", "model:gpt-5.6-terra", "reasoning:medium"])) ==
             ["model:gpt-5.6-terra", "reasoning:medium"]

    assert TaskSettings.fingerprint(issue(nil)) == []
  end

  test "task settings errors have stable diagnostics" do
    assert {:error, {:invalid_task_codex_settings, :labels, :invalid}} =
             TaskSettings.resolve(issue(nil), Config.settings!().codex)

    assert TaskSettings.configuration_error?({:task_configuration_error, :rejected})
    assert TaskSettings.configuration_error?({:invalid_task_codex_settings, :model, :empty})
    refute TaskSettings.configuration_error?(:other_error)

    assert TaskSettings.format_error({:invalid_task_codex_settings, :model, :empty}) ==
             "task label model: must include a value"

    assert TaskSettings.format_error({:invalid_task_codex_settings, :reasoning, {:conflicting, ["high", "low"]}}) ==
             "task labels reasoning: conflict: high, low"

    assert TaskSettings.format_error({:task_configuration_error, :rejected}) ==
             "Codex rejected the task model or reasoning configuration: :rejected"

    assert TaskSettings.format_error(:other_error) ==
             "invalid task Codex configuration: :other_error"
  end

  defp issue(labels) do
    %Issue{id: "issue-settings", identifier: "MT-SETTINGS", title: "Task settings", labels: labels}
  end
end
