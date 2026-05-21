defmodule IdempotencyKit.CoreTest do
  @moduledoc """
  Delegation contract tests for `IdempotencyKit.Core`.
  """

  use ExUnit.Case, async: true

  alias IdempotencyKit.Core

  @state_key {__MODULE__, :fake_store_state}

  defmodule FakeStore do
    @state_key {IdempotencyKit.CoreTest, :fake_store_state}

    def request_hash(payload) do
      send(self(), {:request_hash_called, payload})
      Process.get(@state_key, %{}) |> Map.get(:request_hash, "hash-default")
    end

    def replay_candidate?(user_id, scope, key, payload) do
      send(self(), {:replay_candidate_called, user_id, scope, key, payload})
      Process.get(@state_key, %{}) |> Map.get(:replay_candidate, false)
    end

    def claim_request(user_id, scope, key, request_hash) do
      send(self(), {:claim_request_called, user_id, scope, key, request_hash})
      Process.get(@state_key, %{}) |> Map.get(:claim_result, {:error, :idempotency_unavailable})
    end

    def complete_request(request, status, response_status, response_body) do
      send(
        self(),
        {:complete_request_called, request, status, response_status, response_body}
      )

      Process.get(@state_key, %{}) |> Map.get(:complete_result, {:ok, request})
    end

    def purge_stale_requests do
      send(self(), :purge_stale_requests_called)
      Process.get(@state_key, %{}) |> Map.get(:purge_result, {0, nil})
    end
  end

  # Verifies Core.request_hash/2 delegates straight to the configured store.
  test "request_hash/2 delegates to store request_hash/1" do
    put_state(%{request_hash: "hash-from-store"})

    assert Core.request_hash(FakeStore, %{"a" => 1}) == "hash-from-store"
    assert_received {:request_hash_called, %{"a" => 1}}
  end

  # Verifies Core.replay_candidate?/5 delegates all arguments unchanged.
  test "replay_candidate?/5 delegates to store replay_candidate?/4" do
    put_state(%{replay_candidate: true})

    assert Core.replay_candidate?(FakeStore, 10, "scope", "key", %{"x" => 1})
    assert_received {:replay_candidate_called, 10, "scope", "key", %{"x" => 1}}
  end

  # Verifies Core.claim_request/5 delegates all arguments unchanged.
  test "claim_request/5 delegates to store claim_request/4" do
    put_state(%{claim_result: {:execute, %{id: 1}}})

    assert Core.claim_request(FakeStore, 11, "scope", "key", "hash-value") == {:execute, %{id: 1}}
    assert_received {:claim_request_called, 11, "scope", "key", "hash-value"}
  end

  # Verifies Core.claim_for_payload/5 hashes first and then claims with that hash.
  test "claim_for_payload/5 uses store hash then calls claim_request" do
    put_state(%{
      request_hash: "hash-from-payload",
      claim_result: {:processing, %{id: 2}}
    })

    assert Core.claim_for_payload(FakeStore, 12, "scope", "key", %{"z" => 9}) ==
             {:processing, %{id: 2}}

    assert_received {:request_hash_called, %{"z" => 9}}
    assert_received {:claim_request_called, 12, "scope", "key", "hash-from-payload"}
  end

  # Verifies Core.complete_request/5 delegates completion payload exactly.
  test "complete_request/5 delegates to store complete_request/4" do
    put_state(%{complete_result: {:ok, %{id: 3, status: "succeeded"}}})

    request = %{id: 3, status: "processing"}
    response_body = %{"data" => %{"ok" => true}}

    assert Core.complete_request(FakeStore, request, "succeeded", 200, response_body) ==
             {:ok, %{id: 3, status: "succeeded"}}

    assert_received {:complete_request_called, ^request, "succeeded", 200, ^response_body}
  end

  # Verifies Core.purge_stale_requests/1 delegates and returns store cleanup result.
  test "purge_stale_requests/1 delegates to store purge_stale_requests/0" do
    put_state(%{purge_result: {4, nil}})

    assert Core.purge_stale_requests(FakeStore) == {4, nil}
    assert_received :purge_stale_requests_called
  end

  setup do
    Process.put(@state_key, %{})
    :ok
  end

  defp put_state(state), do: Process.put(@state_key, state)
end
