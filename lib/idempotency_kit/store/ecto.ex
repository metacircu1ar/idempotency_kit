defmodule IdempotencyKit.Store.Ecto do
  @moduledoc """
  Generic Ecto/Postgres helper functions for idempotency stores.

  This module is adapter glue and does not implement a behaviour by itself.
  Host applications typically create a thin module that implements their local
  store behaviour and delegates to these functions with app-specific `Repo`,
  request schema, and config.

  `claim_request/7` options:

  - `:processing_stale_after_seconds` (positive integer, default `300`)
  - `:retention_days` (positive integer, default `14`)
  - `:create_changeset_fun` optional function `(schema_module, attrs) -> Ecto.Changeset.t()`
    used to build the insert changeset.
  """

  import Ecto.Query, only: [from: 2]
  require Logger

  @processing_status "processing"
  @failed_status "failed"
  @succeeded_status "succeeded"
  @default_processing_stale_after_seconds 300
  @default_retention_days 14

  @spec request_hash(term()) :: String.t()
  def request_hash(payload) do
    payload
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Return whether a request is an exact idempotency-key + payload match.

  This is a read-only pre-check for callers that need policy decisions before
  claiming, for example skipping rate-limit consumption for an exact retry. It
  returns `false` for invalid identifiers, missing records, and payload
  mismatches.

  The result is advisory. Call `claim_request/7` for the authoritative lifecycle
  result.
  """
  @spec replay_candidate?(module(), module(), integer(), String.t(), String.t(), term()) ::
          boolean()
  def replay_candidate?(repo, request_schema, user_id, scope, idempotency_key, request_payload)
      when is_integer(user_id) and user_id > 0 do
    with {:ok, normalized_scope} <- normalize_scope(scope),
         {:ok, normalized_key} <- normalize_idempotency_key(idempotency_key) do
      payload_hash = request_hash(request_payload)

      case repo.get_by(request_schema,
             user_id: user_id,
             scope: normalized_scope,
             idempotency_key: normalized_key
           ) do
        %{request_hash: ^payload_hash} -> true
        _ -> false
      end
    else
      _ -> false
    end
  end

  def replay_candidate?(
        _repo,
        _request_schema,
        _user_id,
        _scope,
        _idempotency_key,
        _request_payload
      ),
      do: false

  @spec claim_request(
          module(),
          module(),
          integer(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:execute, IdempotencyKit.Store.request_record()}
          | {:processing, IdempotencyKit.Store.request_record()}
          | {:replay, IdempotencyKit.Store.request_record()}
          | {:error,
             :invalid_key
             | :invalid_scope
             | :invalid_request_hash
             | :payload_mismatch
             | :idempotency_unavailable}
  def claim_request(
        repo,
        request_schema,
        user_id,
        scope,
        idempotency_key,
        request_hash,
        opts \\ []
      )

  def claim_request(
        repo,
        request_schema,
        user_id,
        scope,
        idempotency_key,
        request_hash,
        opts
      )
      when is_integer(user_id) and user_id > 0 do
    with {:ok, normalized_scope} <- normalize_scope(scope),
         {:ok, normalized_key} <- normalize_idempotency_key(idempotency_key),
         {:ok, normalized_hash} <- normalize_request_hash(request_hash) do
      claim_or_fetch_existing(
        repo,
        request_schema,
        user_id,
        normalized_scope,
        normalized_key,
        normalized_hash,
        opts
      )
    end
  end

  def claim_request(
        _repo,
        _request_schema,
        _user_id,
        _scope,
        _idempotency_key,
        _request_hash,
        _opts
      ),
      do: {:error, :idempotency_unavailable}

  @spec complete_request(
          module(),
          module(),
          IdempotencyKit.Store.request_record(),
          String.t(),
          pos_integer(),
          map()
        ) ::
          {:ok, IdempotencyKit.Store.request_record()} | {:error, :idempotency_unavailable}
  def complete_request(repo, request_schema, request, status, response_status, response_body)
      when is_map(request) and is_binary(status) and is_integer(response_status) and
             response_status > 0 and
             is_map(response_body) do
    if status in [@succeeded_status, @failed_status] do
      completed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      updated_at = completed_at |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)

      {updated_count, _} =
        from(r in request_schema, where: r.id == ^request.id and r.status == ^@processing_status)
        |> repo.update_all(
          set: [
            status: status,
            response_status: response_status,
            response_body: response_body,
            completed_at: completed_at,
            updated_at: updated_at
          ]
        )

      case repo.get(request_schema, request.id) do
        persisted_request when is_map(persisted_request) and updated_count in [0, 1] ->
          {:ok, persisted_request}

        _ ->
          {:error, :idempotency_unavailable}
      end
    else
      {:error, :idempotency_unavailable}
    end
  end

  def complete_request(
        _repo,
        _request_schema,
        _request,
        _status,
        _response_status,
        _response_body
      ),
      do: {:error, :idempotency_unavailable}

  @spec purge_stale_requests(module(), module(), keyword()) :: {non_neg_integer(), nil | [term()]}
  def purge_stale_requests(repo, request_schema, opts \\ []) do
    retention_days = retention_days(opts)
    retention_seconds = retention_days * 24 * 60 * 60

    cutoff =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-retention_seconds, :second)
      |> NaiveDateTime.truncate(:second)

    result =
      repo.delete_all(
        from(request in request_schema,
          where: request.inserted_at < ^cutoff
        )
      )

    {deleted_count, _} = result

    Logger.info(
      "Idempotency cleanup completed deleted_count=#{deleted_count} retention_days=#{retention_days} cutoff=#{NaiveDateTime.to_iso8601(cutoff)}"
    )

    result
  end

  defp claim_or_fetch_existing(
         repo,
         request_schema,
         user_id,
         scope,
         idempotency_key,
         request_hash,
         opts
       ) do
    attrs = %{
      user_id: user_id,
      scope: scope,
      idempotency_key: idempotency_key,
      request_hash: request_hash,
      status: @processing_status
    }

    case build_create_changeset(request_schema, attrs, opts) do
      {:ok, changeset} ->
        case repo.insert(changeset,
               on_conflict: :nothing,
               conflict_target: [:user_id, :scope, :idempotency_key]
             ) do
          {:ok, %{id: nil}} ->
            fetch_and_classify_existing(
              repo,
              request_schema,
              user_id,
              scope,
              idempotency_key,
              request_hash,
              opts
            )

          {:ok, request} ->
            {:execute, request}

          {:error, _changeset} ->
            {:error, :idempotency_unavailable}
        end

      {:error, reason} ->
        Logger.warning(
          "Idempotency claim failed: invalid create changeset reason=#{inspect(reason)}"
        )

        {:error, :idempotency_unavailable}
    end
  end

  defp build_create_changeset(request_schema, attrs, opts) do
    create_changeset_fun = Keyword.get(opts, :create_changeset_fun)

    cond do
      is_function(create_changeset_fun, 2) ->
        case create_changeset_fun.(request_schema, attrs) do
          %Ecto.Changeset{} = changeset -> {:ok, changeset}
          _ -> {:error, :invalid_create_changeset}
        end

      function_exported?(request_schema, :create_changeset, 2) ->
        {:ok, request_schema.create_changeset(struct(request_schema), attrs)}

      true ->
        {:ok, default_create_changeset(request_schema, attrs)}
    end
  rescue
    error ->
      Logger.warning(
        "Idempotency claim failed: create changeset builder raised reason=#{inspect(error)}"
      )

      {:error, :invalid_create_changeset}
  end

  defp default_create_changeset(request_schema, attrs) do
    struct(request_schema)
    |> Ecto.Changeset.cast(attrs, [:user_id, :scope, :idempotency_key, :request_hash, :status])
    |> Ecto.Changeset.validate_required([
      :user_id,
      :scope,
      :idempotency_key,
      :request_hash,
      :status
    ])
  end

  defp fetch_and_classify_existing(
         repo,
         request_schema,
         user_id,
         scope,
         idempotency_key,
         request_hash,
         opts
       ) do
    repo.transaction(fn ->
      case lock_request_for_update(repo, request_schema, user_id, scope, idempotency_key) do
        nil ->
          repo.rollback(:idempotency_unavailable)

        %{request_hash: existing_hash} when existing_hash != request_hash ->
          {:error, :payload_mismatch}

        %{status: @processing_status} = request ->
          maybe_reclaim_stale_processing_request(repo, request, opts)

        request when is_map(request) ->
          {:replay, request}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_request_for_update(repo, request_schema, user_id, scope, idempotency_key) do
    repo.one(
      from(request in request_schema,
        where:
          request.user_id == ^user_id and request.scope == ^scope and
            request.idempotency_key == ^idempotency_key,
        lock: "FOR UPDATE"
      )
    )
  end

  defp maybe_reclaim_stale_processing_request(repo, request, opts) do
    if stale_processing_request?(request, opts) do
      case touch_processing_request(repo, request) do
        {:ok, reclaimed_request} -> {:execute, reclaimed_request}
        {:error, _changeset} -> repo.rollback(:idempotency_unavailable)
      end
    else
      {:processing, request}
    end
  end

  defp stale_processing_request?(%{updated_at: %NaiveDateTime{} = updated_at}, opts) do
    NaiveDateTime.diff(NaiveDateTime.utc_now(), updated_at, :second) >
      processing_stale_after_seconds(opts)
  end

  defp stale_processing_request?(_, _opts), do: true

  defp touch_processing_request(repo, request) do
    request
    |> Ecto.Changeset.change(
      updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    )
    |> repo.update()
  end

  defp processing_stale_after_seconds(opts) do
    opts
    |> Keyword.get(:processing_stale_after_seconds, @default_processing_stale_after_seconds)
    |> normalize_positive_int(@default_processing_stale_after_seconds)
  end

  defp retention_days(opts) do
    opts
    |> Keyword.get(:retention_days, @default_retention_days)
    |> normalize_positive_int(@default_retention_days)
  end

  defp normalize_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_positive_int(_, default), do: default

  defp normalize_scope(scope) when is_binary(scope) do
    normalized = String.trim(scope)

    cond do
      normalized == "" -> {:error, :invalid_scope}
      String.length(normalized) > 120 -> {:error, :invalid_scope}
      true -> {:ok, normalized}
    end
  end

  defp normalize_scope(_), do: {:error, :invalid_scope}

  defp normalize_idempotency_key(idempotency_key) when is_binary(idempotency_key) do
    normalized = String.trim(idempotency_key)

    cond do
      normalized == "" -> {:error, :invalid_key}
      String.length(normalized) > 255 -> {:error, :invalid_key}
      true -> {:ok, normalized}
    end
  end

  defp normalize_idempotency_key(_), do: {:error, :invalid_key}

  defp normalize_request_hash(request_hash) when is_binary(request_hash) do
    normalized = String.trim(request_hash)

    cond do
      byte_size(normalized) != 64 -> {:error, :invalid_request_hash}
      String.match?(normalized, ~r/\A[0-9a-f]{64}\z/) -> {:ok, normalized}
      true -> {:error, :invalid_request_hash}
    end
  end

  defp normalize_request_hash(_), do: {:error, :invalid_request_hash}
end
