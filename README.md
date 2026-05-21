# IdempotencyKit

<p align="left">
  <img src="https://raw.githubusercontent.com/metacircu1ar/idempotency_kit/main/logo.png" alt="IdempotencyKit logo" width="180">
</p>

`IdempotencyKit` helps you make mutation endpoints safe to retry.

It is built for Plug/Phoenix apps with Ecto/Postgres.

## Installation

```elixir
def deps do
  [
    {:idempotency_kit, "~> 0.1.0"}
  ]
end
```

## What it does

For the same `(user_id, scope, idempotency_key)`:

1. first request claims execution
2. duplicate while first is running returns `processing`
3. after completion, duplicate replays stored response
4. same key + different payload returns `payload_mismatch`

This prevents accidental duplicate creates when clients retry after lost responses.

## How it works

- payload is hashed deterministically (`sha256`)
- claim row is stored in DB with unique key `(user_id, scope, idempotency_key)`
- action executes once
- final HTTP status/body is persisted
- later duplicates replay that persisted response
- stale `processing` rows can be reclaimed after a timeout

Payload hashing caveat:

- hashing is deterministic for the exact Elixir term shape
- `"1"` and `1` hash differently
- `%{"a" => 1}` and `%{a: 1}` hash differently
- normalize payloads before hashing if your client shapes vary

## Important caveat (read this)

This is a **toolkit**, not a full drop-in service.

You still need to provide:

1. your own Ecto schema + migration for idempotency rows
2. your own Repo module
3. a small app adapter module implementing `IdempotencyKit.Store`
4. a scheduled cleanup job for old rows
5. client-side key generation and retry behavior

So yes, it is app-independent, but host apps must wire the infrastructure around it.

## Real integration examples (YourApp)

Below are concrete examples using a placeholder app name (`YourApp`). This maps
directly to the 5 required host responsibilities above.

### 1) Ecto schema + migration

Paths in YourApp:

- `server/lib/your_app/idempotency/request.ex`
- `server/priv/repo/migrations/<timestamp>_create_idempotency_requests.exs`

```elixir
# server/lib/your_app/idempotency/request.ex
defmodule YourApp.Idempotency.Request do
  use Ecto.Schema
  import Ecto.Changeset

  @all_statuses ["processing", "succeeded", "failed"]
  @completed_statuses ["succeeded", "failed"]

  schema "idempotency_requests" do
    field :scope, :string
    field :idempotency_key, :string
    field :request_hash, :string
    field :status, :string, default: "processing"
    field :response_status, :integer
    field :response_body, :map
    field :completed_at, :utc_datetime
    belongs_to :user, YourApp.Accounts.User
    timestamps()
  end

  def create_changeset(request, attrs) do
    request
    |> cast(attrs, [:user_id, :scope, :idempotency_key, :request_hash, :status])
    |> validate_required([:user_id, :scope, :idempotency_key, :request_hash, :status])
    |> validate_length(:scope, min: 1, max: 120)
    |> validate_length(:idempotency_key, min: 1, max: 255)
    |> validate_length(:request_hash, is: 64)
    |> validate_inclusion(:status, @all_statuses)
    |> unique_constraint(:idempotency_key, name: :idempotency_requests_user_scope_key_idx)
  end

  def completion_changeset(request, attrs) do
    request
    |> cast(attrs, [:status, :response_status, :response_body, :completed_at])
    |> validate_required([:status, :response_status, :response_body, :completed_at])
    |> validate_inclusion(:status, @completed_statuses)
    |> validate_number(:response_status, greater_than_or_equal_to: 100, less_than: 600)
  end
end
```

```elixir
# server/priv/repo/migrations/20260517162721_create_idempotency_requests.exs
def change do
  create table(:idempotency_requests) do
    add :user_id, references(:users, on_delete: :delete_all), null: false
    add :scope, :string, null: false
    add :idempotency_key, :string, null: false
    add :request_hash, :string, null: false
    add :status, :string, null: false, default: "processing"
    add :response_status, :integer
    add :response_body, :map
    add :completed_at, :utc_datetime
    timestamps()
  end

  create constraint(:idempotency_requests, :idempotency_requests_status_check,
           check: "status IN ('processing', 'succeeded', 'failed')"
         )

  create unique_index(:idempotency_requests, [:user_id, :scope, :idempotency_key],
           name: :idempotency_requests_user_scope_key_idx
         )

  create index(:idempotency_requests, [:inserted_at],
           name: :idempotency_requests_inserted_at_idx
         )
end
```

### 2) Repo module

Path in YourApp:

- `server/lib/your_app/repo.ex`

```elixir
defmodule YourApp.Repo do
  use Ecto.Repo,
    otp_app: :your_app,
    adapter: Ecto.Adapters.Postgres
end
```

### 3) App adapter module implementing `IdempotencyKit.Store`

Paths in YourApp:

- `server/lib/your_app/idempotency/store/ecto.ex`
- `server/lib/your_app/idempotency.ex`

```elixir
# server/lib/your_app/idempotency/store/ecto.ex
defmodule YourApp.Idempotency.Store.Ecto do
  @behaviour IdempotencyKit.Store

  alias YourApp.Idempotency.Request
  alias YourApp.Repo
  alias IdempotencyKit.Store.Ecto, as: KitEctoStore

  # Deterministically hash payloads before claim/mismatch checks.
  defdelegate request_hash(payload), to: KitEctoStore

  # Optional read-only exact-retry pre-check. Useful for app policy, such as
  # avoiding a rate-limit debit before the real claim path runs.
  def replay_candidate?(user_id, scope, idempotency_key, request_payload) do
    KitEctoStore.replay_candidate?(
      Repo,
      Request,
      user_id,
      scope,
      idempotency_key,
      request_payload
    )
  end

  # Main claim state machine for execute/processing/replay/mismatch outcomes.
  def claim_request(user_id, scope, idempotency_key, request_hash) do
    KitEctoStore.claim_request(
      Repo,
      Request,
      user_id,
      scope,
      idempotency_key,
      request_hash,
      Application.get_env(:your_app, :idempotency, [])
    )
  end

  # Persist the terminal response used for future idempotent replays.
  def complete_request(request, status, response_status, response_body) do
    KitEctoStore.complete_request(
      Repo,
      Request,
      request,
      status,
      response_status,
      response_body
    )
  end

  # Retention cleanup for old idempotency records.
  def purge_stale_requests do
    KitEctoStore.purge_stale_requests(
      Repo,
      Request,
      Application.get_env(:your_app, :idempotency, [])
    )
  end
end

# server/lib/your_app/idempotency.ex
defmodule YourApp.Idempotency do
  alias YourApp.Idempotency.Store.Ecto, as: EctoStore

  defdelegate request_hash(payload), to: EctoStore

  # Expose the optional exact-retry pre-check for controllers/plugs that need it.
  defdelegate replay_candidate?(user_id, scope, idempotency_key, request_payload),
    to: EctoStore

  defdelegate claim_request(user_id, scope, idempotency_key, request_hash),
    to: EctoStore

  defdelegate complete_request(request, status, response_status, response_body),
    to: EctoStore

  defdelegate purge_stale_requests(), to: EctoStore
end
```

### 4) Scheduled cleanup job

Paths in YourApp:

- `server/lib/your_app/scheduler.ex`
- `server/config/config.exs`

```elixir
# server/lib/your_app/scheduler.ex
defmodule YourApp.Scheduler do
  use Quantum, otp_app: :your_app
end
```

```elixir
# server/config/config.exs
config :your_app, YourApp.Scheduler,
  timezone: "Etc/UTC",
  jobs: [
    cleanup_idempotency_requests: [
      schedule: "@daily",
      task: {YourApp.Idempotency, :purge_stale_requests, []}
    ]
  ]
```

### 5) Client-side key generation and retry behavior

Path in YourApp:

- `client/api.ts`

```ts
function createIdempotencyKey(prefix: string): string {
  const normalizedPrefix = prefix.trim() || "request";
  const randomPart = createRandomId();
  return `${normalizedPrefix}-${randomPart}`;
}

async function requestWithIdempotentProcessingRetry<T>(
  path: string,
  options: RequestInit,
  retryOptions: {
    keyPrefix?: string;
    processingErrorCode: string;
    maxPollAttempts?: number;
    pollDelayMs?: number;
    networkRetryAttempts?: number;
  }
): Promise<T> {
  // Keep one key for one logical submission and all immediate retries.
  const idempotencyKey = createIdempotencyKey(retryOptions.keyPrefix || "request");
  const maxPollAttempts = retryOptions.maxPollAttempts ?? 48;
  const pollDelayMs = retryOptions.pollDelayMs ?? 2500;
  const networkRetryAttempts = retryOptions.networkRetryAttempts ?? 3;
  let attempt = 0;

  while (true) {
    try {
      return await request<T>(
        path,
        {
          ...options,
          headers: {
            ...(options.headers as Record<string, string> | undefined),
            "Idempotency-Key": idempotencyKey
          }
        },
        { networkRetryAttempts }
      );
    } catch (error) {
      const isProcessingError =
        error instanceof ApiRequestError &&
        error.status === 409 &&
        error.code === retryOptions.processingErrorCode;

      if (!isProcessingError || attempt >= maxPollAttempts) {
        throw error;
      }

      attempt += 1;
      await wait(pollDelayMs);
    }
  }
}
```

## Main modules

- `IdempotencyKit.Core` - orchestration helpers
- `IdempotencyKit.Store` - store behaviour
- `IdempotencyKit.Store.Ecto` - generic Ecto/Postgres implementation helpers
- `IdempotencyKit.Phoenix.Action` - controller adapter

## Required storage fields

Your idempotency table should have:

- `user_id`
- `scope`
- `idempotency_key`
- `request_hash` (64-char sha256 hex)
- `status` (`processing|succeeded|failed`)
- `response_status`
- `response_body`
- `completed_at`
- timestamps

Recommended indexes/constraints:

- unique index on `(user_id, scope, idempotency_key)`
- status check constraint
- index on `inserted_at` for cleanup

Schema integration note:

- by default, `IdempotencyKit.Store.Ecto` will call
  `YourSchema.create_changeset(struct(YourSchema), attrs)` if it exists
- if your schema does not expose `create_changeset/2`, pass
  `create_changeset_fun: fn schema_module, attrs -> ... end` in store options

## Copy-paste schema and migration

Example schema:

```elixir
defmodule MyApp.Idempotency.Request do
  use Ecto.Schema
  import Ecto.Changeset

  schema "idempotency_requests" do
    field :scope, :string
    field :idempotency_key, :string
    field :request_hash, :string
    field :status, :string, default: "processing"
    field :response_status, :integer
    field :response_body, :map
    field :completed_at, :utc_datetime

    belongs_to :user, MyApp.Accounts.User

    timestamps()
  end

  def create_changeset(request, attrs) do
    request
    |> cast(attrs, [:user_id, :scope, :idempotency_key, :request_hash, :status])
    |> validate_required([:user_id, :scope, :idempotency_key, :request_hash, :status])
    |> validate_inclusion(:status, ["processing", "succeeded", "failed"])
    |> unique_constraint(:idempotency_key, name: :idempotency_requests_user_scope_key_idx)
  end
end
```

Example migration:

```elixir
def change do
  create table(:idempotency_requests) do
    add :user_id, references(:users, on_delete: :delete_all), null: false
    add :scope, :string, null: false
    add :idempotency_key, :string, null: false
    add :request_hash, :string, null: false
    add :status, :string, null: false, default: "processing"
    add :response_status, :integer
    add :response_body, :map
    add :completed_at, :utc_datetime

    timestamps()
  end

  create unique_index(
           :idempotency_requests,
           [:user_id, :scope, :idempotency_key],
           name: :idempotency_requests_user_scope_key_idx
         )

  create constraint(
           :idempotency_requests,
           :idempotency_requests_status_check,
           check: "status IN ('processing', 'succeeded', 'failed')"
         )

  create index(:idempotency_requests, [:inserted_at])
end
```

## Cleanup

The library does not schedule cleanup for you.

Run a periodic job (for example daily) that calls your store purge function.

## Controller usage example

```elixir
defmodule MyAppWeb.EntityController do
  use MyAppWeb, :controller

  alias IdempotencyKit.Phoenix.Action, as: IdempotentAction

  @idempotency_scope "entity_create"

  def create(
        conn,   # Plug.Conn for the incoming HTTP request.
        params  # Request payload; this is hashed for idempotency matching.
      ) do
    user = conn.assigns.current_user

    execute_fun = fn idempotent_conn ->
      # Runs only when claim result is :execute.
      create_entity(idempotent_conn, user, params)
    end

    case IdempotentAction.maybe_run_for_user(
           conn,                       # incoming conn
           user.id,                    # unique partition by user
           @idempotency_scope,         # action scope
           params,                     # payload used to compute request hash
           execute_fun,                # mutation closure
           idempotency_opts(user.id)   # adapter options
         ) do
      {:handled, handled_conn} ->
        # Already handled by idempotency adapter (execute/replay/error).
        handled_conn

      {:no_key, plain_conn} ->
        # No key header: fallback non-idempotent path.
        create_entity(plain_conn, user, params)
    end
  end

  defp idempotency_opts(user_id) do
    [
      # Required: module exporting request_hash/1, claim_request/4, complete_request/4.
      idempotency_module: MyApp.Idempotency,

      # Optional: your standardized API error renderer.
      render_error_fun: &MyAppWeb.ApiHelpers.render_error/4,

      # Optional: log prefix.
      log_context: "Entity controller user=#{user_id}"
    ]
  end
end
```

## `Idempotency-Key` header

Default header name is `Idempotency-Key` (read as `idempotency-key` in Plug).

You can override the header per endpoint with `opts[:header]`, but using the
default is recommended.

## Typical client behavior

For mutation endpoints:

1. generate a new key per user action
2. send it in `Idempotency-Key`
3. retry network failures with the same key
4. if you retry with edited payload, use a new key

## Package integration tests (Postgres)

The package includes Postgres-backed integration tests for the real Ecto
lifecycle semantics:

- claim -> processing -> complete -> replay
- payload mismatch conflicts
- stale processing reclaim
- retention purge
- concurrent identical claims

By default these tests are excluded.

Run them by setting:

- `IDEMPOTENCY_KIT_TEST_DATABASE_URL`

Example:

```bash
IDEMPOTENCY_KIT_TEST_DATABASE_URL=postgres://postgres:postgres@localhost:5432/idempotency_kit_test \
  mix test --include integration test/idempotency_kit/store_ecto_integration_test.exs
```

## Replacing DB storage with Redis

You can use Redis instead of the Ecto/Postgres helper.

The callback interface is currently (v0.1.0):

- `request_hash/1`
- `replay_candidate?/4`
- `claim_request/4`
- `complete_request/4`
- `purge_stale_requests/0`

To do this, implement your own store module with `@behaviour IdempotencyKit.Store`:

```elixir
defmodule MyApp.Idempotency.RedisStore do
  @behaviour IdempotencyKit.Store

  # Deterministically hash payload. Same logical payload must hash the same way.
  def request_hash(payload), do: ...

  # Optional read-only pre-check for callers that want to detect an exact retry
  # before claim. Return true only when key + payload hash matches an existing
  # idempotency record. Still call claim_request/4 for the authoritative result.
  def replay_candidate?(user_id, scope, idempotency_key, request_payload), do: ...

  # Main claim state machine:
  # - first request => {:execute, request}
  # - duplicate in-flight => {:processing, request}
  # - completed request with same hash => {:replay, request}
  # - same key + different hash => {:error, :payload_mismatch}
  def claim_request(user_id, scope, idempotency_key, request_hash), do: ...

  # Persist terminal outcome for a claimed request.
  # `request` should be what you returned from claim_request/4.
  # Replayed records must include response_status + response_body.
  def complete_request(request, status, response_status, response_body), do: ...

  # Retention cleanup for old rows/keys.
  def purge_stale_requests(), do: ...
end
```

Then pass your Redis-backed module as `idempotency_module` in controller options.

Note: `replay_candidate?/4` is part of the `IdempotencyKit.Store` behaviour,
but the Phoenix adapter itself only requires:
`request_hash/1`, `claim_request/4`, and `complete_request/4`.

Important requirements for Redis:

1. `claim_request/4` must be atomic (Lua script is recommended).
2. Keep the same lifecycle semantics:
   - first request => `{:execute, request}`
   - duplicate in-flight => `{:processing, request}`
   - same key + different payload => `{:error, :payload_mismatch}`
   - completed request => `{:replay, request}`
   - replay request should include `response_status` and `response_body`
     (atom or string keys) so the Phoenix adapter can render it
3. Support stale processing reclaim (or enforce a bounded processing TTL).
4. Set retention/TTL for old completed requests.

Note: Redis can work very well here, but make sure your durability settings
(AOF/RDB/replication) match your reliability expectations.
