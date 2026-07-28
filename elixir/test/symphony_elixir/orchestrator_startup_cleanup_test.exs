defmodule SymphonyElixir.OrchestratorStartupCleanupTest do
  use SymphonyElixir.TestSupport

  test "external reclaimer owns startup cleanup when configured" do
    previous_value = System.get_env("SYMPHONY_EXTERNAL_WORKSPACE_RECLAIMER")
    System.put_env("SYMPHONY_EXTERNAL_WORKSPACE_RECLAIMER", "true")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    on_exit(fn ->
      restore_env("SYMPHONY_EXTERNAL_WORKSPACE_RECLAIMER", previous_value)
    end)

    orchestrator_name =
      Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")

    log =
      capture_log(fn ->
        assert {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        try do
          assert %{running: []} = Orchestrator.snapshot(orchestrator_name, 1_000)
        after
          GenServer.stop(pid)
        end
      end)

    assert log =~ "external reclaimer is configured"
  end
end
