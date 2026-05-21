defmodule IdempotencyKit.Phoenix.Action do
  @moduledoc """
  Reusable Plug/Phoenix adapter for idempotent controller actions.

  This module is host-app agnostic. Supply app-specific callbacks via options:

  - `:idempotency_module` (required): module implementing
    `request_hash/1`, `claim_request/4`, and `complete_request/4`
  - `:render_error_fun` (optional): `(conn, status, detail, metadata) -> conn`
  """

  import Plug.Conn,
    only: [
      get_req_header: 2,
      get_resp_header: 2,
      put_private: 3,
      put_resp_header: 3,
      put_status: 2,
      register_before_send: 2
    ]

  import Phoenix.Controller, only: [json: 2]

  require Logger

  @idempotency_header "idempotency-key"
  @captured_response_body_private_key :idempotency_captured_response_body

  @type response_status :: atom() | integer()
  @type error_spec :: %{
          required(:status) => response_status(),
          required(:detail) => String.t(),
          optional(:code) => String.t(),
          optional(:metadata) => map()
        }
  @type persist_result ::
          {:ok, String.t(), pos_integer(), map()} | {:error, term()}
  @type persist_response_fun :: (Plug.Conn.t(), term() -> persist_result())
  @type replay_response_fun ::
          (Plug.Conn.t(), term() -> {:ok, Plug.Conn.t()} | :default | {:error, term()})
  @type render_error_fun ::
          (Plug.Conn.t(), response_status(), String.t(), map() -> Plug.Conn.t())

  @doc false
  @spec idempotency_key(Plug.Conn.t(), String.t() | nil) :: String.t() | nil
  def idempotency_key(conn, header_name \\ @idempotency_header)

  def idempotency_key(conn, header_name) when is_binary(header_name) do
    conn
    |> get_req_header(header_name)
    |> List.first()
    |> case do
      value when is_binary(value) ->
        normalized = String.trim(value)
        if normalized == "", do: nil, else: normalized

      _ ->
        nil
    end
  end

  def idempotency_key(conn, _), do: idempotency_key(conn, @idempotency_header)

  @doc false
  @spec captured_response_body(Plug.Conn.t()) :: term()
  def captured_response_body(%Plug.Conn{private: private})
      when is_map(private),
      do: Map.get(private, @captured_response_body_private_key)

  def captured_response_body(_), do: nil

  @spec maybe_run(Plug.Conn.t(), keyword(), (Plug.Conn.t() -> Plug.Conn.t())) ::
          {:handled, Plug.Conn.t()} | {:no_key, Plug.Conn.t()}
  def maybe_run(conn, opts, execute_fun) when is_function(execute_fun, 1) do
    case idempotency_key(conn, Keyword.get(opts, :header, @idempotency_header)) do
      nil ->
        {:no_key, conn}

      key ->
        {:handled, run_with_key(conn, key, opts, execute_fun)}
    end
  end

  @spec maybe_run_for_user(
          Plug.Conn.t(),
          pos_integer(),
          String.t(),
          term(),
          (Plug.Conn.t() -> Plug.Conn.t()),
          keyword()
        ) :: {:handled, Plug.Conn.t()} | {:no_key, Plug.Conn.t()}
  def maybe_run_for_user(conn, user_id, scope, request_payload, execute_fun, opts \\ [])
      when is_integer(user_id) and user_id > 0 and is_binary(scope) and
             is_function(execute_fun, 1) and
             is_list(opts) do
    merged_opts =
      opts
      |> Keyword.merge(
        user_id: user_id,
        scope: scope,
        request_payload: request_payload
      )

    maybe_run(conn, merged_opts, execute_fun)
  end

  defp run_with_key(conn, idempotency_key, opts, execute_fun) do
    idempotency_module = idempotency_module!(opts)
    user_id = Keyword.fetch!(opts, :user_id)
    scope = Keyword.fetch!(opts, :scope)
    request_payload = Keyword.get(opts, :request_payload, %{})
    request_hash = idempotency_module.request_hash(request_payload)

    case idempotency_module.claim_request(user_id, scope, idempotency_key, request_hash) do
      {:execute, request} when is_map(request) ->
        execute_and_persist(
          conn,
          request,
          idempotency_module,
          idempotency_key,
          opts,
          execute_fun
        )

      {:processing, _request} ->
        render_configured_error(conn, opts, :processing_error, default_processing_error())

      {:replay, request} when is_map(request) ->
        replay_response(conn, request, idempotency_key, opts)

      {:error, :payload_mismatch} ->
        render_configured_error(
          conn,
          opts,
          :payload_mismatch_error,
          default_payload_mismatch_error()
        )

      {:error, reason} when reason in [:invalid_key, :invalid_scope, :invalid_request_hash] ->
        render_configured_error(conn, opts, :invalid_key_error, default_invalid_key_error())

      {:error, reason} ->
        log_warn(
          opts,
          "claim failed key=#{inspect(idempotency_key)} reason=#{inspect(reason)}"
        )

        render_configured_error(conn, opts, :unavailable_error, default_unavailable_error())

      other ->
        log_warn(
          opts,
          "claim returned unexpected result key=#{inspect(idempotency_key)} result=#{inspect(other)}"
        )

        render_configured_error(conn, opts, :unavailable_error, default_unavailable_error())
    end
  end

  defp execute_and_persist(
         conn,
         request,
         idempotency_module,
         idempotency_key,
         opts,
         execute_fun
       )
       when is_map(request) do
    try do
      response_conn =
        conn
        |> register_response_body_capture()
        |> execute_fun.()
        |> ensure_response_conn!()

      case persist_response(request, idempotency_module, response_conn, opts) do
        :ok ->
          response_conn

        {:error, reason} ->
          log_warn(
            opts,
            "completion failed key=#{inspect(idempotency_key)} request_id=#{request_id(request)} reason=#{inspect(reason)}"
          )

          response_conn
      end
    rescue
      error ->
        mark_crashed_request(
          request,
          idempotency_module,
          idempotency_key,
          opts,
          {:error, error, __STACKTRACE__}
        )

        reraise(error, __STACKTRACE__)
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__

        mark_crashed_request(
          request,
          idempotency_module,
          idempotency_key,
          opts,
          {kind, reason, stacktrace}
        )

        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp persist_response(request, idempotency_module, response_conn, opts) when is_map(request) do
    case build_persist_payload(response_conn, request, opts) do
      {:ok, request_status, status, response_body} ->
        case idempotency_module.complete_request(request, request_status, status, response_body) do
          {:ok, _updated_request} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_persist_payload(response_conn, request, opts) when is_map(request) do
    case Keyword.get(opts, :persist_response_fun) do
      persist_fun when is_function(persist_fun, 2) ->
        case persist_fun.(response_conn, request) do
          {:ok, request_status, status, response_body}
          when is_binary(request_status) and is_integer(status) and is_map(response_body) ->
            normalized_status = normalize_status(status)

            normalized_request_status =
              normalize_request_status(request_status, normalized_status)

            {:ok, normalized_request_status, normalized_status, response_body}

          {:error, reason} ->
            {:error, reason}

          _ ->
            {:error, :invalid_persist_response}
        end

      _ ->
        status = normalize_status(response_conn.status)

        response_body =
          response_conn
          |> captured_response_body()
          |> fallback_response_body(response_conn.resp_body)
          |> decode_response_body()

        request_status = if(status >= 200 and status < 300, do: "succeeded", else: "failed")
        {:ok, request_status, status, response_body}
    end
  end

  defp register_response_body_capture(conn) do
    register_before_send(conn, fn before_send_conn ->
      put_private(
        before_send_conn,
        @captured_response_body_private_key,
        before_send_conn.resp_body
      )
    end)
  end

  defp fallback_response_body(nil, fallback), do: fallback
  defp fallback_response_body(value, _fallback), do: value

  defp normalize_request_status(status, _response_status)
       when is_binary(status) and status in ["succeeded", "failed"],
       do: status

  defp normalize_request_status(_, response_status)
       when response_status >= 200 and response_status < 300,
       do: "succeeded"

  defp normalize_request_status(_, _), do: "failed"

  defp mark_crashed_request(request, idempotency_module, idempotency_key, opts, crash)
       when is_map(request) do
    crash_error = build_error_spec(Keyword.get(opts, :crash_error, default_crash_error()))

    log_warn(
      opts,
      "execution crashed key=#{inspect(idempotency_key)} request_id=#{request_id(request)} crash=#{inspect(crash)}"
    )

    payload = crash_error_payload(crash_error)

    case idempotency_module.complete_request(request, "failed", 500, payload) do
      {:ok, _updated_request} ->
        :ok

      {:error, reason} ->
        log_warn(
          opts,
          "crash completion failed key=#{inspect(idempotency_key)} request_id=#{request_id(request)} reason=#{inspect(reason)}"
        )

        :error
    end
  end

  defp replay_response(conn, request, idempotency_key, opts) when is_map(request) do
    replayable_conn =
      conn
      |> put_resp_header("x-idempotency-status", "replayed")

    case maybe_custom_replay_response(replayable_conn, request, opts) do
      {:ok, custom_conn} ->
        log_info(
          opts,
          "event=idempotency_replay mode=custom key=#{inspect(idempotency_key)} request_id=#{request_id(request)}"
        )

        custom_conn

      :default ->
        replay_response_from_payload(replayable_conn, request, idempotency_key, opts)

      {:error, reason} ->
        log_warn(
          opts,
          "custom replay failed key=#{inspect(idempotency_key)} request_id=#{request_id(request)} reason=#{inspect(reason)}"
        )

        render_configured_error(conn, opts, :unavailable_error, default_unavailable_error())
    end
  end

  defp maybe_custom_replay_response(conn, request, opts) when is_map(request) do
    case Keyword.get(opts, :replay_response_fun) do
      replay_fun when is_function(replay_fun, 2) ->
        case replay_fun.(conn, request) do
          {:ok, %Plug.Conn{} = replay_conn} -> {:ok, replay_conn}
          :default -> :default
          {:error, reason} -> {:error, reason}
          _ -> {:error, :invalid_replay_response}
        end

      _ ->
        :default
    end
  end

  defp replay_response_from_payload(conn, request, idempotency_key, opts) when is_map(request) do
    status = request_response_status(request)
    response_body = request_response_body(request)

    if is_integer(status) and status >= 100 and status < 600 and is_map(response_body) do
      log_info(
        opts,
        "event=idempotency_replay mode=payload key=#{inspect(idempotency_key)} request_id=#{request_id(request)} status=#{status}"
      )

      conn
      |> put_status(status)
      |> json(response_body)
    else
      log_warn(
        opts,
        "event=idempotency_replay_failed reason=missing_response_payload key=#{inspect(idempotency_key)} request_id=#{request_id(request)}"
      )

      render_configured_error(conn, opts, :unavailable_error, default_unavailable_error())
    end
  end

  defp render_configured_error(conn, opts, key, default_spec) do
    configured = Keyword.get(opts, key, default_spec)
    spec = build_error_spec(configured)

    metadata =
      spec.metadata
      |> sanitize_error_metadata()
      |> maybe_put_code(spec.code)

    render_error(conn, spec.status, spec.detail, metadata, opts)
  end

  defp build_error_spec(spec) when is_map(spec) do
    %{
      status: Map.get(spec, :status, :service_unavailable),
      detail: Map.get(spec, :detail, "Unable to process request right now."),
      code: Map.get(spec, :code),
      metadata: normalize_metadata(Map.get(spec, :metadata, %{}))
    }
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_), do: %{}

  defp sanitize_error_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      normalized_key = normalize_metadata_key(key)

      if normalized_key in ["detail", "code"] do
        acc
      else
        Map.put(acc, normalized_key, value)
      end
    end)
  end

  defp sanitize_error_metadata(_), do: %{}

  defp normalize_metadata_key(key) when is_binary(key), do: key
  defp normalize_metadata_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_metadata_key(key), do: inspect(key)

  defp maybe_put_code(metadata, nil), do: metadata
  defp maybe_put_code(metadata, ""), do: metadata
  defp maybe_put_code(metadata, code), do: Map.put(metadata, "code", code)

  defp crash_error_payload(crash_error) do
    base_payload =
      %{"detail" => crash_error.detail}
      |> maybe_put_code(crash_error.code)

    %{
      "errors" =>
        crash_error.metadata
        |> sanitize_error_metadata()
        |> Map.merge(base_payload)
    }
  end

  defp ensure_response_conn!(%Plug.Conn{} = conn), do: conn

  defp ensure_response_conn!(result) do
    raise ArgumentError,
          "idempotent execute_fun must return %Plug.Conn{}, got: #{inspect(result)}"
  end

  defp normalize_status(status) when is_integer(status) and status >= 100 and status < 600,
    do: status

  defp normalize_status(_), do: 500

  defp decode_response_body(body) when is_binary(body) or is_list(body) do
    case maybe_response_body_binary(body) do
      {:ok, binary} ->
        case Jason.decode(binary) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> %{}
        end

      :error ->
        %{}
    end
  end

  defp decode_response_body(_), do: %{}

  defp maybe_response_body_binary(body) when is_binary(body), do: {:ok, body}

  defp maybe_response_body_binary(body) when is_list(body) do
    try do
      {:ok, IO.iodata_to_binary(body)}
    rescue
      _ -> :error
    end
  end

  defp render_error(conn, status, detail, metadata, opts) do
    render_error_fun =
      Keyword.get(opts, :render_error_fun, fn render_conn,
                                              render_status,
                                              render_detail,
                                              render_metadata ->
        default_render_error(render_conn, render_status, render_detail, render_metadata)
      end)

    case render_error_fun.(conn, status, detail, metadata) do
      %Plug.Conn{} = rendered_conn -> rendered_conn
      _ -> default_render_error(conn, status, detail, metadata)
    end
  end

  defp default_render_error(conn, status, detail, metadata) do
    error_payload =
      %{detail: detail}
      |> Map.merge(metadata || %{})

    conn
    |> maybe_put_retry_after(status)
    |> put_status(status)
    |> json(%{errors: error_payload})
  end

  defp maybe_put_retry_after(conn, status) do
    if too_many_requests_status?(status) and get_resp_header(conn, "retry-after") == [] do
      put_resp_header(conn, "retry-after", "60")
    else
      conn
    end
  end

  defp too_many_requests_status?(:too_many_requests), do: true
  defp too_many_requests_status?(429), do: true
  defp too_many_requests_status?(_), do: false

  defp request_id(request) when is_map(request) do
    Map.get(request, :id) || Map.get(request, "id")
  end

  defp request_response_status(request) when is_map(request) do
    Map.get(request, :response_status) || Map.get(request, "response_status")
  end

  defp request_response_body(request) when is_map(request) do
    Map.get(request, :response_body) || Map.get(request, "response_body")
  end

  defp log_info(opts, message), do: log(opts, :info, message)
  defp log_warn(opts, message), do: log(opts, :warning, message)

  defp log(opts, level, message) do
    context =
      opts
      |> Keyword.get(:log_context, "Idempotent action")
      |> to_string()
      |> String.trim()

    formatted =
      if context == "" do
        message
      else
        "#{context} #{message}"
      end

    Logger.log(level, formatted)
  end

  defp idempotency_module!(opts) do
    module =
      case Keyword.get(opts, :idempotency_module) do
        selected when is_atom(selected) and not is_nil(selected) -> selected
        _ -> raise ArgumentError, "missing required :idempotency_module option"
      end

    required_callbacks = [
      {:request_hash, 1},
      {:claim_request, 4},
      {:complete_request, 4}
    ]

    case Enum.find(required_callbacks, fn {name, arity} ->
           not function_exported?(module, name, arity)
         end) do
      nil ->
        module

      {name, arity} ->
        raise ArgumentError,
              ":idempotency_module #{inspect(module)} must export #{name}/#{arity}"
    end
  end

  defp default_processing_error do
    %{
      status: :conflict,
      detail: "Request is still processing. Please try again shortly.",
      code: "idempotency_request_in_progress"
    }
  end

  defp default_payload_mismatch_error do
    %{
      status: :conflict,
      detail: "Idempotency key was already used with a different request payload.",
      code: "idempotency_key_payload_mismatch"
    }
  end

  defp default_invalid_key_error do
    %{
      status: :bad_request,
      detail: "Invalid idempotency key.",
      code: "invalid_idempotency_key"
    }
  end

  defp default_unavailable_error do
    %{
      status: :service_unavailable,
      detail: "Unable to process request right now.",
      code: "idempotency_unavailable"
    }
  end

  defp default_crash_error do
    %{
      detail: "Request failed unexpectedly. Please try again.",
      code: "idempotency_execution_failed"
    }
  end
end
