defmodule IdempotencyKit.Store.EctoTest do
  @moduledoc """
  Unit tests for non-DB edge behavior in `IdempotencyKit.Store.Ecto`.
  """

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias IdempotencyKit.Store.Ecto, as: EctoStore

  defmodule InsertSpyRepo do
    def insert(changeset, opts) do
      send(self(), {:insert_called, changeset, opts})
      {:error, %Ecto.Changeset{}}
    end
  end

  defmodule SchemaWithCreateChangeset do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    schema "idempotency_requests" do
      field(:user_id, :integer)
      field(:scope, :string)
      field(:idempotency_key, :string)
      field(:request_hash, :string)
      field(:status, :string)
    end

    def create_changeset(request, attrs) do
      request
      |> cast(attrs, [:user_id, :scope, :idempotency_key, :request_hash, :status])
      |> validate_required([:user_id, :scope, :idempotency_key, :request_hash, :status])
      |> put_change(:scope, "from_schema_create_changeset")
    end
  end

  defmodule SchemaWithoutCreateChangeset do
    use Ecto.Schema

    @primary_key false
    schema "idempotency_requests" do
      field(:user_id, :integer)
      field(:scope, :string)
      field(:idempotency_key, :string)
      field(:request_hash, :string)
      field(:status, :string)
    end
  end

  # Verifies hash determinism for equivalent map payloads with different key order.
  test "request_hash/1 is deterministic for equivalent maps" do
    payload_a = %{"a" => 1, "b" => %{"x" => 2, "y" => 3}}
    payload_b = %{"b" => %{"y" => 3, "x" => 2}, "a" => 1}

    assert EctoStore.request_hash(payload_a) == EctoStore.request_hash(payload_b)
  end

  # Verifies atom-key and string-key maps intentionally hash differently.
  test "request_hash/1 differs for atom-key vs string-key maps" do
    payload_atom_keys = %{a: 1}
    payload_string_keys = %{"a" => 1}

    refute EctoStore.request_hash(payload_atom_keys) ==
             EctoStore.request_hash(payload_string_keys)
  end

  # Verifies numeric type differences are preserved by hashing (int vs float).
  test "request_hash/1 differs for integer and float payload values" do
    payload_int = %{"value" => 1}
    payload_float = %{"value" => 1.0}

    refute EctoStore.request_hash(payload_int) == EctoStore.request_hash(payload_float)
  end

  # Verifies non-map payloads are supported and hash deterministically.
  test "request_hash/1 supports non-map payloads deterministically" do
    payload = [{:tuple, 1}, [1, 2, 3], "abc", 10]

    assert EctoStore.request_hash(payload) == EctoStore.request_hash(payload)
  end

  # Verifies invalid user IDs fail closed without requiring any repo interaction.
  test "claim_request/7 returns unavailable for non-positive user_id" do
    assert EctoStore.claim_request(nil, nil, 0, "scope", "key", String.duplicate("a", 64), []) ==
             {:error, :idempotency_unavailable}

    assert EctoStore.claim_request(nil, nil, -1, "scope", "key", String.duplicate("a", 64), []) ==
             {:error, :idempotency_unavailable}
  end

  # Verifies invalid scope/key/hash inputs are rejected before DB interaction.
  test "claim_request/7 validates scope, key, and hash input shape" do
    hash = String.duplicate("a", 64)

    assert EctoStore.claim_request(nil, nil, 1, "", "key", hash, []) == {:error, :invalid_scope}
    assert EctoStore.claim_request(nil, nil, 1, "scope", "", hash, []) == {:error, :invalid_key}

    assert EctoStore.claim_request(nil, nil, 1, "scope", "key", "short", []) ==
             {:error, :invalid_request_hash}
  end

  # Verifies scope length boundaries (120 allowed, 121 rejected).
  test "claim_request/7 enforces scope length boundaries" do
    scope_120 = String.duplicate("s", 120)
    scope_121 = String.duplicate("s", 121)

    # Invalid hash proves scope passed validation and function moved to hash validation.
    assert EctoStore.claim_request(nil, nil, 1, scope_120, "key", "short", []) ==
             {:error, :invalid_request_hash}

    assert EctoStore.claim_request(nil, nil, 1, scope_121, "key", String.duplicate("a", 64), []) ==
             {:error, :invalid_scope}
  end

  # Verifies idempotency key length boundaries (255 allowed, 256 rejected).
  test "claim_request/7 enforces idempotency key length boundaries" do
    key_255 = String.duplicate("k", 255)
    key_256 = String.duplicate("k", 256)

    # Invalid hash proves key passed validation and function moved to hash validation.
    assert EctoStore.claim_request(nil, nil, 1, "scope", key_255, "short", []) ==
             {:error, :invalid_request_hash}

    assert EctoStore.claim_request(nil, nil, 1, "scope", key_256, String.duplicate("a", 64), []) ==
             {:error, :invalid_key}
  end

  # Verifies request hash boundaries and lowercase hex validation.
  test "claim_request/7 enforces request hash length and lowercase hex format" do
    hash_63 = String.duplicate("a", 63)
    hash_65 = String.duplicate("a", 65)
    hash_non_hex = String.duplicate("g", 64)
    hash_uppercase = String.duplicate("A", 64)

    assert EctoStore.claim_request(nil, nil, 1, "scope", "key", hash_63, []) ==
             {:error, :invalid_request_hash}

    assert EctoStore.claim_request(nil, nil, 1, "scope", "key", hash_65, []) ==
             {:error, :invalid_request_hash}

    assert EctoStore.claim_request(nil, nil, 1, "scope", "key", hash_non_hex, []) ==
             {:error, :invalid_request_hash}

    assert EctoStore.claim_request(nil, nil, 1, "scope", "key", hash_uppercase, []) ==
             {:error, :invalid_request_hash}
  end

  # Verifies scope/key are trimmed before length checks and downstream validation.
  test "claim_request/7 trims scope and key before validating lengths" do
    scope_120 = String.duplicate("s", 120)
    key_255 = String.duplicate("k", 255)

    # Should pass scope/key validation after trim, then fail at hash validation.
    assert EctoStore.claim_request(nil, nil, 1, "  #{scope_120}  ", "  #{key_255}  ", "short", []) ==
             {:error, :invalid_request_hash}
  end

  # Verifies replay_candidate?/6 fails closed on invalid identifying inputs.
  test "replay_candidate?/6 returns false for invalid arguments" do
    payload = %{"email" => "tester@example.com"}

    refute EctoStore.replay_candidate?(nil, nil, 0, "scope", "key", payload)
    refute EctoStore.replay_candidate?(nil, nil, 1, "", "key", payload)
    refute EctoStore.replay_candidate?(nil, nil, 1, "scope", "", payload)
  end

  # Verifies completion rejects non-terminal statuses without touching persistence.
  test "complete_request/6 rejects non-terminal status values" do
    assert EctoStore.complete_request(nil, nil, %{id: 1}, "processing", 200, %{}) ==
             {:error, :idempotency_unavailable}
  end

  # Verifies completion rejects invalid response status code values.
  test "complete_request/6 rejects invalid HTTP response status values" do
    assert EctoStore.complete_request(nil, nil, %{id: 1}, "succeeded", 0, %{}) ==
             {:error, :idempotency_unavailable}
  end

  # Verifies custom create_changeset_fun is used when provided, even if schema exports create_changeset/2.
  test "claim_request/7 uses custom create_changeset_fun override" do
    create_changeset_fun = fn schema_module, attrs ->
      send(self(), {:custom_changeset_called, schema_module, attrs})

      schema_module
      |> struct()
      |> Ecto.Changeset.cast(attrs, [:user_id, :scope, :idempotency_key, :request_hash, :status])
      |> Ecto.Changeset.validate_required([
        :user_id,
        :scope,
        :idempotency_key,
        :request_hash,
        :status
      ])
      |> Ecto.Changeset.put_change(:scope, "from_custom_changeset_fun")
    end

    assert EctoStore.claim_request(
             InsertSpyRepo,
             SchemaWithCreateChangeset,
             1,
             "scope",
             "key",
             valid_hash(),
             create_changeset_fun: create_changeset_fun
           ) == {:error, :idempotency_unavailable}

    assert_received {:custom_changeset_called, SchemaWithCreateChangeset, attrs}
    assert attrs.scope == "scope"
    assert attrs.idempotency_key == "key"
    assert attrs.request_hash == valid_hash()
    assert attrs.status == "processing"

    assert_received {:insert_called, changeset, insert_opts}
    assert changeset.changes.scope == "from_custom_changeset_fun"
    assert insert_opts[:on_conflict] == :nothing
    assert insert_opts[:conflict_target] == [:user_id, :scope, :idempotency_key]
  end

  # Verifies invalid custom create_changeset_fun return values fail closed before repo interaction.
  test "claim_request/7 rejects non-changeset custom create_changeset_fun result" do
    assert EctoStore.claim_request(
             InsertSpyRepo,
             SchemaWithoutCreateChangeset,
             1,
             "scope",
             "key",
             valid_hash(),
             create_changeset_fun: fn _, _ -> :not_a_changeset end
           ) == {:error, :idempotency_unavailable}

    refute_received {:insert_called, _, _}
  end

  # Verifies raised custom create_changeset_fun errors are logged and fail closed.
  test "claim_request/7 handles raised custom create_changeset_fun with warning" do
    log =
      capture_log(fn ->
        assert EctoStore.claim_request(
                 InsertSpyRepo,
                 SchemaWithoutCreateChangeset,
                 1,
                 "scope",
                 "key",
                 valid_hash(),
                 create_changeset_fun: fn _, _ -> raise "boom in custom changeset builder" end
               ) == {:error, :idempotency_unavailable}
      end)

    assert log =~ "create changeset builder raised"
    refute_received {:insert_called, _, _}
  end

  # Verifies schema-level create_changeset/2 is used when no custom function is provided.
  test "claim_request/7 uses schema create_changeset/2 when exported" do
    assert EctoStore.claim_request(
             InsertSpyRepo,
             SchemaWithCreateChangeset,
             1,
             "scope",
             "key",
             valid_hash(),
             []
           ) == {:error, :idempotency_unavailable}

    assert_received {:insert_called, changeset, _opts}
    assert changeset.changes.scope == "from_schema_create_changeset"
  end

  # Verifies default cast/validate fallback is used when schema has no create_changeset/2.
  test "claim_request/7 falls back to default create changeset when schema has no helper" do
    assert EctoStore.claim_request(
             InsertSpyRepo,
             SchemaWithoutCreateChangeset,
             1,
             "scope",
             "key",
             valid_hash(),
             []
           ) == {:error, :idempotency_unavailable}

    assert_received {:insert_called, changeset, _opts}
    assert changeset.valid?
    assert changeset.changes.scope == "scope"
    assert changeset.changes.idempotency_key == "key"
    assert changeset.changes.request_hash == valid_hash()
    assert changeset.changes.status == "processing"
  end

  defp valid_hash, do: String.duplicate("a", 64)
end
