defmodule IdempotencyKit.Store.EctoIntegrationTest do
  @moduledoc """
  Postgres-backed integration coverage for `IdempotencyKit.Store.Ecto`.

  These tests are intentionally opt-in:
  set `IDEMPOTENCY_KIT_TEST_DATABASE_URL` and run with `--include integration`.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias IdempotencyKit.Store.Ecto, as: EctoStore

  @moduletag :integration

  defmodule TestRepo do
    use Ecto.Repo,
      otp_app: :idempotency_kit,
      adapter: Ecto.Adapters.Postgres
  end

  defmodule TestRequest do
    use Ecto.Schema
    import Ecto.Changeset

    schema "idempotency_kit_test_requests" do
      field(:user_id, :integer)
      field(:scope, :string)
      field(:idempotency_key, :string)
      field(:request_hash, :string)
      field(:status, :string)
      field(:response_status, :integer)
      field(:response_body, :map)
      field(:completed_at, :utc_datetime)

      # Use second precision to match the helper's normalization behavior.
      timestamps(type: :naive_datetime)
    end

    def create_changeset(request, attrs) do
      # Intentionally no unique_constraint here: race/conflict behavior is validated
      # against the database unique index via `on_conflict: :nothing`.
      request
      |> cast(attrs, [:user_id, :scope, :idempotency_key, :request_hash, :status])
      |> validate_required([:user_id, :scope, :idempotency_key, :request_hash, :status])
    end
  end

  # Verifies full lifecycle: execute -> processing -> complete -> replay.
  test "claim lifecycle executes once and then replays completed response" do
    payload = %{"duration" => 45}
    key = unique_key("lifecycle")
    hash = EctoStore.request_hash(payload)

    assert {:execute, request} = claim_request(1, "scope", key, hash)
    assert {:processing, _request} = claim_request(1, "scope", key, hash)

    assert {:ok, _completed} =
             EctoStore.complete_request(TestRepo, TestRequest, request, "succeeded", 200, %{
               "data" => %{"workout_id" => 123}
             })

    assert {:replay, replay_request} = claim_request(1, "scope", key, hash)
    assert replay_request.status == "succeeded"
    assert replay_request.response_status == 200
    assert replay_request.response_body == %{"data" => %{"workout_id" => 123}}
  end

  # Verifies same key with a different payload hash returns payload mismatch.
  test "payload mismatch is returned for same key with different request hash" do
    key = unique_key("mismatch")
    hash_a = EctoStore.request_hash(%{"duration" => 45})
    hash_b = EctoStore.request_hash(%{"duration" => 60})

    assert {:execute, _request} = claim_request(2, "scope", key, hash_a)
    assert {:error, :payload_mismatch} = claim_request(2, "scope", key, hash_b)
  end

  # Verifies stale processing rows become reclaimable as :execute.
  test "stale processing requests are reclaimed" do
    key = unique_key("stale")
    hash = EctoStore.request_hash(%{"duration" => 45})

    assert {:execute, request} = claim_request(3, "scope", key, hash)

    stale_updated_at =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-10, :second)
      |> NaiveDateTime.truncate(:second)

    TestRepo.update_all(
      from(r in TestRequest, where: r.id == ^request.id),
      set: [updated_at: stale_updated_at]
    )

    assert {:execute, reclaimed_request} =
             claim_request(3, "scope", key, hash, processing_stale_after_seconds: 1)

    assert reclaimed_request.id == request.id
    assert NaiveDateTime.compare(reclaimed_request.updated_at, stale_updated_at) == :gt
  end

  # Verifies fresh processing rows remain :processing and are not reclaimed early.
  test "fresh processing requests remain processing" do
    key = unique_key("fresh")
    hash = EctoStore.request_hash(%{"duration" => 45})

    assert {:execute, _request} = claim_request(4, "scope", key, hash)
    assert {:processing, _request} = claim_request(4, "scope", key, hash)
  end

  # Verifies retention cleanup removes old rows and keeps fresh rows.
  test "purge_stale_requests deletes old rows and keeps fresh rows" do
    old_inserted_at =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-3 * 24 * 60 * 60, :second)
      |> NaiveDateTime.truncate(:second)

    old_completed_at =
      DateTime.utc_now()
      |> DateTime.add(-3 * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)

    old_request =
      TestRepo.insert!(%TestRequest{
        user_id: 5,
        scope: "scope",
        idempotency_key: unique_key("old"),
        request_hash: EctoStore.request_hash(%{"duration" => 30}),
        status: "succeeded",
        response_status: 200,
        response_body: %{"data" => %{"id" => 1}},
        completed_at: old_completed_at,
        inserted_at: old_inserted_at,
        updated_at: old_inserted_at
      })

    fresh_request =
      TestRepo.insert!(%TestRequest{
        user_id: 5,
        scope: "scope",
        idempotency_key: unique_key("fresh"),
        request_hash: EctoStore.request_hash(%{"duration" => 60}),
        status: "succeeded",
        response_status: 200,
        response_body: %{"data" => %{"id" => 2}},
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    assert {1, nil} = EctoStore.purge_stale_requests(TestRepo, TestRequest, retention_days: 1)
    refute TestRepo.get(TestRequest, old_request.id)
    assert TestRepo.get(TestRequest, fresh_request.id)
  end

  # Verifies concurrent claims produce exactly one execute winner for identical payloads.
  test "concurrent identical claims yield one execute and remaining processing" do
    user_id = 6
    scope = "scope"
    key = unique_key("race")
    hash = EctoStore.request_hash(%{"duration" => 45})
    parent = self()

    results =
      1..8
      |> Task.async_stream(
        fn _ ->
          Ecto.Adapters.SQL.Sandbox.allow(TestRepo, parent, self())
          claim_request(user_id, scope, key, hash)
        end,
        max_concurrency: 8,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:execute, %TestRequest{}}, &1)) == 1
    assert Enum.count(results, &match?({:processing, %TestRequest{}}, &1)) == 7
  end

  # Verifies completion is write-once and later completion attempts do not overwrite.
  test "complete_request/6 does not overwrite an already terminal request" do
    payload = %{"duration" => 45}
    key = unique_key("write-once")
    hash = EctoStore.request_hash(payload)

    assert {:execute, request} = claim_request(7, "scope", key, hash)

    assert {:ok, _completed} =
             EctoStore.complete_request(TestRepo, TestRequest, request, "succeeded", 201, %{
               "data" => %{"id" => 100}
             })

    assert {:ok, persisted_again} =
             EctoStore.complete_request(TestRepo, TestRequest, request, "failed", 500, %{
               "errors" => %{"detail" => "should_not_overwrite"}
             })

    assert persisted_again.status == "succeeded"
    assert persisted_again.response_status == 201
    assert persisted_again.response_body == %{"data" => %{"id" => 100}}
  end

  # Verifies invalid HTTP status is rejected and leaves the row in processing state.
  test "complete_request/6 rejects invalid response status without mutating row" do
    payload = %{"duration" => 30}
    key = unique_key("invalid-status")
    hash = EctoStore.request_hash(payload)

    assert {:execute, request} = claim_request(8, "scope", key, hash)

    assert {:error, :idempotency_unavailable} =
             EctoStore.complete_request(TestRepo, TestRequest, request, "succeeded", 0, %{})

    persisted = TestRepo.get!(TestRequest, request.id)
    assert persisted.status == "processing"
    assert is_nil(persisted.response_status)
    assert is_nil(persisted.response_body)
    assert is_nil(persisted.completed_at)
  end

  setup_all do
    database_url = database_url!()

    Application.put_env(:idempotency_kit, TestRepo,
      url: database_url,
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 10,
      log: false
    )

    {:ok, _pid} = TestRepo.start_link()

    # Run setup DDL in :auto mode so setup queries are owned and committed.
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :auto)

    Ecto.Adapters.SQL.query!(
      TestRepo,
      """
      DROP TABLE IF EXISTS idempotency_kit_test_requests
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      TestRepo,
      """
      CREATE TABLE idempotency_kit_test_requests (
        id BIGSERIAL PRIMARY KEY,
        user_id BIGINT NOT NULL,
        scope VARCHAR(120) NOT NULL,
        idempotency_key VARCHAR(255) NOT NULL,
        request_hash CHAR(64) NOT NULL,
        status VARCHAR(16) NOT NULL,
        response_status INTEGER,
        response_body JSONB,
        completed_at TIMESTAMPTZ,
        inserted_at TIMESTAMP(6) WITHOUT TIME ZONE NOT NULL,
        updated_at TIMESTAMP(6) WITHOUT TIME ZONE NOT NULL
      )
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      TestRepo,
      """
      CREATE UNIQUE INDEX idempotency_kit_test_requests_user_scope_key_index
        ON idempotency_kit_test_requests (user_id, scope, idempotency_key)
      """,
      []
    )

    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)

    :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)

    :ok
  end

  defp claim_request(user_id, scope, idempotency_key, request_hash, opts \\ []) do
    EctoStore.claim_request(
      TestRepo,
      TestRequest,
      user_id,
      scope,
      idempotency_key,
      request_hash,
      opts
    )
  end

  defp unique_key(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp database_url! do
    case System.get_env("IDEMPOTENCY_KIT_TEST_DATABASE_URL") do
      nil ->
        raise """
        Missing IDEMPOTENCY_KIT_TEST_DATABASE_URL for integration tests.
        Example:
          IDEMPOTENCY_KIT_TEST_DATABASE_URL=postgres://postgres:postgres@localhost:5432/idempotency_kit_test \
            mix test --include integration test/idempotency_kit/store_ecto_integration_test.exs
        """

      value when is_binary(value) ->
        normalized = String.trim(value)

        if normalized == "" do
          raise "IDEMPOTENCY_KIT_TEST_DATABASE_URL cannot be blank for integration tests"
        else
          normalized
        end
    end
  end
end
