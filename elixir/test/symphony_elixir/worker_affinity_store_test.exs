defmodule SymphonyElixir.WorkerAffinityStoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkerAffinityStore

  test "persists assignments atomically and reloads them" do
    root = Path.join(System.tmp_dir!(), "symphony-affinity-#{System.unique_integer([:positive])}")
    path = Path.join(root, "affinities.json")
    hosts = ["worker-0", "worker-1"]
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, %{"issue-1" => "worker-1"} = affinities} =
             WorkerAffinityStore.put(path, %{}, "issue-1", "worker-1", hosts)

    refute File.exists?(path <> ".tmp")
    assert {:ok, ^affinities} = WorkerAffinityStore.load(path, hosts)

    assert {:ok, %{}} = WorkerAffinityStore.delete(path, affinities, "issue-1", hosts)
    assert {:ok, %{}} = WorkerAffinityStore.load(path, hosts)
  end

  test "rejects corrupt state and assignments to unknown hosts" do
    root = Path.join(System.tmp_dir!(), "symphony-affinity-#{System.unique_integer([:positive])}")
    path = Path.join(root, "affinities.json")
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(path, ~s({"version":1,"affinities":{"issue-1":"worker-9"}}))

    assert {:error, :invalid_affinity_state} = WorkerAffinityStore.load(path, ["worker-0"])

    assert {:error, :invalid_affinity_state} =
             WorkerAffinityStore.put(path, %{}, "issue-1", "worker-9", ["worker-0"])
  end

  test "rejects assigning one worker to multiple issue owners" do
    hosts = ["worker-0", "worker-1"]

    assert {:error, {:worker_affinity_owned, "worker-0", "issue-1"}} =
             WorkerAffinityStore.put(
               nil,
               %{"issue-1" => "worker-0"},
               "issue-2",
               "worker-0",
               hosts
             )

    assert {:ok, %{"issue-1" => "worker-0", "issue-2" => "worker-1"}} =
             WorkerAffinityStore.put(
               nil,
               %{"issue-1" => "worker-0"},
               "issue-2",
               "worker-1",
               hosts
             )
  end

  test "promotes an explicit migration seed only when durable state is absent" do
    root = Path.join(System.tmp_dir!(), "symphony-affinity-#{System.unique_integer([:positive])}")
    path = Path.join(root, "affinities.json")
    seed_path = Path.join(root, "seed.json")
    hosts = ["worker-0", "worker-1"]
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    File.write!(
      seed_path,
      Jason.encode!(%{version: 1, affinities: %{"issue-1" => "worker-1"}})
    )

    assert {:ok, %{"issue-1" => "worker-1"}} =
             WorkerAffinityStore.load(path, seed_path, hosts)

    assert File.exists?(path)

    File.write!(
      seed_path,
      Jason.encode!(%{version: 1, affinities: %{"issue-2" => "worker-0"}})
    )

    assert {:ok, %{"issue-1" => "worker-1"}} =
             WorkerAffinityStore.load(path, seed_path, hosts)
  end

  test "handles disabled, missing, malformed, and inaccessible state safely" do
    root = Path.join(System.tmp_dir!(), "symphony-affinity-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    assert {:ok, %{}} = WorkerAffinityStore.load(nil, ["worker-0"])
    assert :ok = WorkerAffinityStore.persist(nil, %{"issue-1" => "worker-0"})

    missing_seed = Path.join(root, "missing-seed.json")
    state_path = Path.join(root, "state.json")
    assert {:ok, %{}} = WorkerAffinityStore.load(state_path, ["worker-0"])
    assert {:ok, %{}} = WorkerAffinityStore.load(state_path, missing_seed, ["worker-0"])

    File.write!(state_path, ~s({"version":2,"affinities":{}}))

    assert {:error, :invalid_affinity_state} =
             WorkerAffinityStore.load(state_path, ["worker-0"])

    assert {:error, {:affinity_state_read_failed, _reason}} =
             WorkerAffinityStore.load(root, ["worker-0"])
  end

  test "reports atomic write and seed promotion failures" do
    root = Path.join(System.tmp_dir!(), "symphony-affinity-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    parent_file = Path.join(root, "not-a-directory")
    File.write!(parent_file, "occupied")
    unwritable_path = Path.join(parent_file, "state.json")

    assert {:error, {:affinity_state_write_failed, _reason}} =
             WorkerAffinityStore.persist(unwritable_path, %{})

    seed_path = Path.join(root, "seed.json")
    File.write!(seed_path, ~s({"version":1,"affinities":{"issue-1":"worker-0"}}))
    promotion_path = Path.join(root, "promotion.json")
    File.mkdir_p!(promotion_path <> ".tmp")

    assert {:error, {:affinity_seed_failed, {:affinity_state_write_failed, _reason}}} =
             WorkerAffinityStore.load(promotion_path, seed_path, ["worker-0"])

    invalid_seed_path = Path.join(root, "invalid-seed.json")
    File.write!(invalid_seed_path, "invalid")

    assert {:error, {:affinity_seed_failed, {:invalid_affinity_state, _reason}}} =
             WorkerAffinityStore.load(
               Path.join(root, "absent-state.json"),
               invalid_seed_path,
               ["worker-0"]
             )
  end
end
