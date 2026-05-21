defmodule IdempotencyKit.Core do
  @moduledoc """
  Backend-agnostic idempotency flow helpers.
  """

  alias IdempotencyKit.Store

  @spec request_hash(module(), term()) :: String.t()
  def request_hash(store, payload) when is_atom(store) do
    store.request_hash(payload)
  end

  @doc """
  Delegate an exact-retry pre-check to the configured store.

  Returns `true` when the store already has a record for the same
  `(user_id, scope, idempotency_key)` and equivalent payload hash.
  """
  @spec replay_candidate?(module(), integer(), String.t(), String.t(), term()) :: boolean()
  def replay_candidate?(store, user_id, scope, idempotency_key, request_payload)
      when is_atom(store) do
    store.replay_candidate?(user_id, scope, idempotency_key, request_payload)
  end

  @spec claim_request(module(), integer(), String.t(), String.t(), String.t()) ::
          Store.claim_result()
  def claim_request(store, user_id, scope, idempotency_key, request_hash)
      when is_atom(store) do
    store.claim_request(user_id, scope, idempotency_key, request_hash)
  end

  @spec claim_for_payload(module(), integer(), String.t(), String.t(), term()) ::
          Store.claim_result()
  @doc """
  Convenience helper that hashes payload and then delegates to `claim_request/5`.

  Useful for callers that prefer a single-step API.
  """
  def claim_for_payload(store, user_id, scope, idempotency_key, request_payload)
      when is_atom(store) do
    request_hash = request_hash(store, request_payload)
    claim_request(store, user_id, scope, idempotency_key, request_hash)
  end

  @spec complete_request(module(), term(), String.t(), pos_integer(), map()) ::
          {:ok, term()} | {:error, :idempotency_unavailable}
  def complete_request(store, request, status, response_status, response_body)
      when is_atom(store) do
    store.complete_request(request, status, response_status, response_body)
  end

  @spec purge_stale_requests(module()) :: {non_neg_integer(), nil | [term()]}
  def purge_stale_requests(store) when is_atom(store) do
    store.purge_stale_requests()
  end
end
