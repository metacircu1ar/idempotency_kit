defmodule IdempotencyKit.Store do
  @moduledoc """
  Behaviour for idempotency persistence backends.

  A store backend owns the idempotency state machine for one logical key:

  - key identity: `(user_id, scope, idempotency_key)`
  - payload identity: `request_hash`
  - lifecycle: `processing -> succeeded|failed`

  Expected `claim_request/4` semantics:

  - first claim for `(user_id, scope, key, hash)` -> `{:execute, request}`
  - same key while first request is still in progress -> `{:processing, request}`
  - same key after completion with same hash -> `{:replay, request}`
  - same key with different hash -> `{:error, :payload_mismatch}`

  `request` can be an Ecto struct or any map-like record, but replay handling in
  `IdempotencyKit.Phoenix.Action` requires it to expose `response_status` and
  `response_body` (atom or string keys).
  """

  @typedoc """
  Request map returned from `claim_request/4`.

  The Phoenix adapter expects map access and uses these fields on replay:
  - `:response_status` or `"response_status"`
  - `:response_body` or `"response_body"`
  """
  @type request_record :: %{optional(atom()) => term(), optional(String.t()) => term()}

  @type claim_error ::
          :invalid_key
          | :invalid_scope
          | :invalid_request_hash
          | :payload_mismatch
          | :idempotency_unavailable

  @type claim_result ::
          {:execute, request_record()}
          | {:processing, request_record()}
          | {:replay, request_record()}
          | {:error, claim_error()}

  @doc """
  Deterministically hash a request payload.

  The result should be stable for equivalent payload shapes in your app.
  """
  @callback request_hash(term()) :: String.t()

  @doc """
  Optional read-only pre-check used by callers that want to detect an exact retry
  before attempting a write claim.

  Return `true` only when the same `(user_id, scope, idempotency_key)` already
  exists with the same request payload hash. Return `false` for missing keys,
  mismatched payloads, invalid identifiers, or backend uncertainty.

  This helper is useful for host-app policy decisions, such as skipping a
  rate-limit debit for an exact retry. It does not replace `claim_request/4`;
  callers must still claim to get the authoritative execute/processing/replay
  outcome.

  This callback is part of the store behaviour, but it is not required by the
  Phoenix adapter.
  """
  @callback replay_candidate?(integer(), String.t(), String.t(), term()) :: boolean()

  @doc """
  Claim request ownership for one `(user_id, scope, idempotency_key, request_hash)`.

  Must implement the state-machine semantics documented in this module.
  """
  @callback claim_request(integer(), String.t(), String.t(), String.t()) :: claim_result()

  @doc """
  Persist terminal outcome for a claimed request.

  `status` is expected to be a terminal value (typically `"succeeded"` or `"failed"`),
  and `response_status` + `response_body` should be stored so replay can return
  the original HTTP response.
  """
  @callback complete_request(request_record(), String.t(), pos_integer(), map()) ::
              {:ok, request_record()} | {:error, :idempotency_unavailable}

  @doc """
  Remove stale request records based on backend retention policy.
  """
  @callback purge_stale_requests() :: {non_neg_integer(), nil | [term()]}
end
