defmodule IdempotencyKit.Phoenix.ActionTest do
  @moduledoc """
  Focused tests for the package-level Phoenix adapter.

  These tests use fake idempotency modules to validate action lifecycle behavior
  without a database dependency.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3, put_status: 2]

  alias IdempotencyKit.Phoenix.Action

  @state_key {__MODULE__, :fake_store_state}
  @default_hash String.duplicate("a", 64)

  defmodule FakeIdempotencyModule do
    @state_key {IdempotencyKit.Phoenix.ActionTest, :fake_store_state}
    @default_hash String.duplicate("a", 64)

    def request_hash(payload) do
      send(self(), {:request_hash_called, payload})
      state = Process.get(@state_key, %{})

      case Map.get(state, :request_hash_fun) do
        fun when is_function(fun, 1) -> fun.(payload)
        _ -> Map.get(state, :request_hash, @default_hash)
      end
    end

    def claim_request(user_id, scope, idempotency_key, request_hash) do
      send(self(), {:claim_request_called, user_id, scope, idempotency_key, request_hash})
      state = Process.get(@state_key, %{})

      case Map.get(state, :claim_results, []) do
        [next | rest] ->
          Process.put(@state_key, Map.put(state, :claim_results, rest))
          resolve_claim(next, user_id, scope, idempotency_key, request_hash)

        [] ->
          resolve_claim(
            Map.get(state, :claim_result, {:error, :idempotency_unavailable}),
            user_id,
            scope,
            idempotency_key,
            request_hash
          )
      end
    end

    def complete_request(request, status, response_status, response_body) do
      send(
        self(),
        {:complete_request_called, request, status, response_status, response_body}
      )

      state = Process.get(@state_key, %{})

      case Map.get(state, :complete_result) do
        fun when is_function(fun, 4) ->
          fun.(request, status, response_status, response_body)

        nil ->
          {:ok, Map.put(request, :status, status)}

        result ->
          result
      end
    end

    defp resolve_claim(fun, user_id, scope, idempotency_key, request_hash)
         when is_function(fun, 4) do
      fun.(user_id, scope, idempotency_key, request_hash)
    end

    defp resolve_claim(result, _user_id, _scope, _idempotency_key, _request_hash), do: result
  end

  defmodule MissingRequestHashModule do
    def claim_request(_user_id, _scope, _idempotency_key, _request_hash), do: {:error, :ignored}
    def complete_request(_request, _status, _response_status, _response_body), do: {:ok, %{}}
  end

  defmodule MissingClaimRequestModule do
    def request_hash(_payload), do: String.duplicate("a", 64)
    def complete_request(_request, _status, _response_status, _response_body), do: {:ok, %{}}
  end

  defmodule MissingCompleteRequestModule do
    def request_hash(_payload), do: String.duplicate("a", 64)
    def claim_request(_user_id, _scope, _idempotency_key, _request_hash), do: {:error, :ignored}
  end

  # Verifies default header extraction trims surrounding whitespace.
  test "idempotency_key/2 trims default header values" do
    conn = Plug.Test.conn("POST", "/") |> put_req_header("idempotency-key", "  key-123  ")
    assert Action.idempotency_key(conn) == "key-123"
  end

  # Verifies custom header selection and blank-header normalization to nil.
  test "idempotency_key/2 supports custom header and blank values" do
    conn =
      Plug.Test.conn("POST", "/")
      |> put_req_header("x-custom-idempotency", "custom-456")
      |> put_req_header("idempotency-key", "   ")

    assert Action.idempotency_key(conn, "x-custom-idempotency") == "custom-456"
    assert Action.idempotency_key(conn) == nil
  end

  # Verifies requests without idempotency key bypass the adapter path.
  test "maybe_run/3 returns :no_key when no key is present" do
    execute_fun = fn conn ->
      send(self(), :executed)
      conn |> put_status(:ok) |> json(%{"data" => %{"ok" => true}})
    end

    conn = Plug.Test.conn("POST", "/test")
    opts = base_opts()

    assert {:no_key, returned_conn} = Action.maybe_run(conn, opts, execute_fun)
    assert returned_conn == conn
    refute_received :executed
  end

  # Verifies maybe_run/3 reads key from opts[:header] and executes idempotent flow.
  test "maybe_run/3 supports custom header name through opts[:header]" do
    put_fake_store_state(%{
      claim_result: {:execute, processing_request(9)}
    })

    conn =
      Plug.Test.conn("POST", "/test")
      |> put_req_header("accept", "application/json")
      |> put_req_header("x-my-key", "custom-key-123")

    opts = base_opts(header: "x-my-key")

    assert {:handled, response_conn} =
             Action.maybe_run(conn, opts, fn execute_conn ->
               execute_conn |> put_status(:ok) |> json(%{"data" => %{"ok" => true}})
             end)

    assert response_conn.status == 200

    assert_received {:claim_request_called, 11, "idempotency_kit_test_scope", "custom-key-123",
                     @default_hash}
  end

  # Verifies first execution calls complete_request with captured success payload.
  test "execute path completes request with captured JSON response" do
    put_fake_store_state(%{
      claim_result: {:execute, processing_request(10)}
    })

    assert {:handled, response_conn} =
             run_action(fn conn ->
               conn
               |> put_status(:created)
               |> json(%{"data" => %{"id" => 42}})
             end)

    assert response_conn.status == 201
    assert decoded_json(response_conn) == %{"data" => %{"id" => 42}}

    assert_receive {:complete_request_called, %{id: 10}, "succeeded", 201,
                    %{"data" => %{"id" => 42}}}
  end

  # Verifies replayed responses include replay header and atom-key payload support.
  test "replay path returns persisted response with replay header for atom keys" do
    put_fake_store_state(%{
      claim_result: {:replay, replay_request_atom_keys(20, 200, %{"data" => %{"id" => 7}})}
    })

    assert {:handled, replay_conn} = run_action(fn _ -> flunk("execute_fun should not run") end)

    assert replay_conn.status == 200
    assert decoded_json(replay_conn) == %{"data" => %{"id" => 7}}
    assert get_resp_header(replay_conn, "x-idempotency-status") == ["replayed"]
  end

  # Verifies replayed responses also work when persisted request uses string keys.
  test "replay path returns persisted response for string-key requests" do
    put_fake_store_state(%{
      claim_result: {:replay, replay_request_string_keys(21, 202, %{"data" => %{"id" => 8}})}
    })

    assert {:handled, replay_conn} = run_action(fn _ -> flunk("execute_fun should not run") end)

    assert replay_conn.status == 202
    assert decoded_json(replay_conn) == %{"data" => %{"id" => 8}}
    assert get_resp_header(replay_conn, "x-idempotency-status") == ["replayed"]
  end

  # Verifies in-flight duplicate claims map to the processing conflict response.
  test "processing claim returns processing error payload" do
    put_fake_store_state(%{claim_result: {:processing, processing_request(30)}})

    assert {:handled, response_conn} = run_action(fn _ -> flunk("execute_fun should not run") end)

    assert response_conn.status == 409

    assert decoded_json(response_conn) == %{
             "errors" => %{
               "detail" => "Request is still processing. Please try again shortly.",
               "code" => "idempotency_request_in_progress"
             }
           }
  end

  # Verifies payload mismatch claims map to the dedicated conflict response.
  test "payload mismatch claim returns conflict payload mismatch response" do
    put_fake_store_state(%{claim_result: {:error, :payload_mismatch}})

    assert {:handled, response_conn} = run_action(fn _ -> flunk("execute_fun should not run") end)

    assert response_conn.status == 409

    assert decoded_json(response_conn) == %{
             "errors" => %{
               "detail" => "Idempotency key was already used with a different request payload.",
               "code" => "idempotency_key_payload_mismatch"
             }
           }
  end

  # Verifies invalid-key class errors are normalized to the invalid key response.
  test "invalid key/scope/hash claim errors return invalid idempotency key response" do
    for reason <- [:invalid_key, :invalid_scope, :invalid_request_hash] do
      put_fake_store_state(%{claim_result: {:error, reason}})

      assert {:handled, response_conn} =
               run_action(fn _ -> flunk("execute_fun should not run") end)

      assert response_conn.status == 400

      assert decoded_json(response_conn) == %{
               "errors" => %{
                 "detail" => "Invalid idempotency key.",
                 "code" => "invalid_idempotency_key"
               }
             }
    end
  end

  # Verifies store-unavailable claims surface 503 fallback and preserve operation safety.
  test "idempotency unavailable claim returns 503 unavailable error" do
    put_fake_store_state(%{claim_result: {:error, :idempotency_unavailable}})

    log =
      capture_log(fn ->
        assert {:handled, response_conn} =
                 run_action(fn _ -> flunk("execute_fun should not run") end)

        assert response_conn.status == 503
      end)

    assert log =~ "claim failed"
  end

  # Verifies blank log_context does not add leading formatting noise to log lines.
  test "blank log_context logs message without prefixed context text" do
    put_fake_store_state(%{claim_result: {:error, :idempotency_unavailable}})

    opts = base_opts(log_context: "   ")

    log =
      capture_log(fn ->
        assert {:handled, response_conn} =
                 run_action_with_opts(opts, fn _ -> flunk("execute_fun should not run") end)

        assert response_conn.status == 503
      end)

    assert log =~ "claim failed key="
    refute log =~ "  claim failed key="
  end

  # Verifies unexpected claim return values fail closed to unavailable.
  test "unexpected claim result fails closed with unavailable response" do
    put_fake_store_state(%{claim_result: :unexpected})

    log =
      capture_log(fn ->
        assert {:handled, response_conn} =
                 run_action(fn _ -> flunk("execute_fun should not run") end)

        assert response_conn.status == 503
      end)

    assert log =~ "unexpected result"
  end

  # Verifies configured error overrides can set custom status/detail/code/metadata.
  test "configured processing error override renders custom payload and retry-after" do
    put_fake_store_state(%{claim_result: {:processing, processing_request(40)}})

    opts =
      base_opts(
        processing_error: %{
          status: :too_many_requests,
          detail: "Still running.",
          code: "generation_pending",
          metadata: %{retry_after_hint: "60s"}
        }
      )

    assert {:handled, response_conn} =
             run_action_with_opts(opts, fn _ -> flunk("execute_fun should not run") end)

    assert response_conn.status == 429
    assert get_resp_header(response_conn, "retry-after") == ["60"]

    assert decoded_json(response_conn) == %{
             "errors" => %{
               "detail" => "Still running.",
               "code" => "generation_pending",
               "retry_after_hint" => "60s"
             }
           }
  end

  # Verifies reserved metadata keys cannot override canonical detail/code fields.
  test "error metadata sanitization strips reserved keys and stringifies atom keys" do
    put_fake_store_state(%{claim_result: {:processing, processing_request(41)}})

    opts =
      base_opts(
        processing_error: %{
          status: :conflict,
          detail: "Canonical detail",
          code: "canonical_code",
          metadata: %{
            detail: "ignored",
            code: "ignored",
            custom_atom: "ok"
          }
        }
      )

    assert {:handled, response_conn} =
             run_action_with_opts(opts, fn _ -> flunk("execute_fun should not run") end)

    assert decoded_json(response_conn) == %{
             "errors" => %{
               "detail" => "Canonical detail",
               "code" => "canonical_code",
               "custom_atom" => "ok"
             }
           }
  end

  # Verifies custom render_error_fun output is used when it returns a Plug.Conn.
  test "custom render_error_fun can override error rendering" do
    put_fake_store_state(%{claim_result: {:processing, processing_request(50)}})

    opts =
      base_opts(
        render_error_fun: fn conn, status, detail, metadata ->
          conn
          |> put_status(status)
          |> json(%{"custom_error" => %{"detail" => detail, "metadata" => metadata}})
        end
      )

    assert {:handled, response_conn} =
             run_action_with_opts(opts, fn _ -> flunk("execute_fun should not run") end)

    assert response_conn.status == 409

    assert decoded_json(response_conn) == %{
             "custom_error" => %{
               "detail" => "Request is still processing. Please try again shortly.",
               "metadata" => %{"code" => "idempotency_request_in_progress"}
             }
           }
  end

  # Verifies invalid custom render_error_fun return falls back to default renderer.
  test "invalid custom render_error_fun return falls back to default error renderer" do
    put_fake_store_state(%{claim_result: {:processing, processing_request(51)}})

    opts =
      base_opts(render_error_fun: fn _conn, _status, _detail, _metadata -> :not_a_conn end)

    assert {:handled, response_conn} =
             run_action_with_opts(opts, fn _ -> flunk("execute_fun should not run") end)

    assert response_conn.status == 409
    assert decoded_json(response_conn)["errors"]["code"] == "idempotency_request_in_progress"
  end

  # Verifies custom persist hook can override completion status/body payload.
  test "persist_response_fun successful return is persisted through complete_request" do
    put_fake_store_state(%{
      claim_result: {:execute, processing_request(60)}
    })

    opts =
      base_opts(
        persist_response_fun: fn _conn, _request ->
          {:ok, "failed", 422, %{"errors" => %{"detail" => "Validation failed"}}}
        end
      )

    assert {:handled, response_conn} =
             run_action_with_opts(opts, fn conn ->
               conn |> put_status(:created) |> json(%{"data" => %{"id" => 99}})
             end)

    assert response_conn.status == 201

    assert_receive {:complete_request_called, %{id: 60}, "failed", 422,
                    %{
                      "errors" => %{"detail" => "Validation failed"}
                    }}
  end

  # Verifies persist hook failures do not crash and leave original response untouched.
  test "persist_response_fun error returns response and skips completion write" do
    put_fake_store_state(%{
      claim_result: {:execute, processing_request(61)}
    })

    opts =
      base_opts(persist_response_fun: fn _conn, _request -> {:error, :persist_failed} end)

    log =
      capture_log(fn ->
        assert {:handled, response_conn} =
                 run_action_with_opts(opts, fn conn ->
                   conn |> put_status(:ok) |> json(%{"data" => %{"ok" => true}})
                 end)

        assert response_conn.status == 200
      end)

    assert log =~ "completion failed"
    refute_received {:complete_request_called, _, _, _, _}
  end

  # Verifies invalid persist hook return values fail softly without crashing callers.
  test "persist_response_fun invalid return fails softly and skips completion write" do
    put_fake_store_state(%{
      claim_result: {:execute, processing_request(62)}
    })

    opts =
      base_opts(persist_response_fun: fn _conn, _request -> :invalid end)

    log =
      capture_log(fn ->
        assert {:handled, response_conn} =
                 run_action_with_opts(opts, fn conn ->
                   conn |> put_status(:ok) |> json(%{"data" => %{"ok" => true}})
                 end)

        assert response_conn.status == 200
      end)

    assert log =~ "completion failed"
    refute_received {:complete_request_called, _, _, _, _}
  end

  # Verifies custom replay hook can fully override replay response rendering.
  test "replay_response_fun can return custom replay conn" do
    put_fake_store_state(%{
      claim_result: {:replay, replay_request_atom_keys(70, 200, %{"data" => %{"id" => 1}})}
    })

    opts =
      base_opts(
        replay_response_fun: fn conn, _request ->
          {:ok, conn |> put_status(:accepted) |> json(%{"data" => %{"custom" => true}})}
        end
      )

    assert {:handled, response_conn} =
             run_action_with_opts(opts, fn _ -> flunk("execute_fun should not run") end)

    assert response_conn.status == 202
    assert decoded_json(response_conn) == %{"data" => %{"custom" => true}}
    assert get_resp_header(response_conn, "x-idempotency-status") == ["replayed"]
  end

  # Verifies replay hook can explicitly fall back to persisted payload path.
  test "replay_response_fun :default falls through to persisted payload replay" do
    put_fake_store_state(%{
      claim_result: {:replay, replay_request_atom_keys(71, 207, %{"data" => %{"id" => 2}})}
    })

    opts =
      base_opts(replay_response_fun: fn _conn, _request -> :default end)

    assert {:handled, response_conn} =
             run_action_with_opts(opts, fn _ -> flunk("execute_fun should not run") end)

    assert response_conn.status == 207
    assert decoded_json(response_conn) == %{"data" => %{"id" => 2}}
  end

  # Verifies replay hook errors fail closed with unavailable response.
  test "replay_response_fun error returns unavailable response" do
    put_fake_store_state(%{
      claim_result: {:replay, replay_request_atom_keys(72, 200, %{"data" => %{"id" => 3}})}
    })

    opts =
      base_opts(replay_response_fun: fn _conn, _request -> {:error, :replay_failed} end)

    assert {:handled, response_conn} =
             run_action_with_opts(opts, fn _ -> flunk("execute_fun should not run") end)

    assert response_conn.status == 503
    assert decoded_json(response_conn)["errors"]["code"] == "idempotency_unavailable"
  end

  # Verifies invalid replay hook return values fail closed with unavailable response.
  test "replay_response_fun invalid return returns unavailable response" do
    put_fake_store_state(%{
      claim_result: {:replay, replay_request_atom_keys(73, 200, %{"data" => %{"id" => 4}})}
    })

    opts =
      base_opts(replay_response_fun: fn _conn, _request -> :invalid end)

    assert {:handled, response_conn} =
             run_action_with_opts(opts, fn _ -> flunk("execute_fun should not run") end)

    assert response_conn.status == 503
    assert decoded_json(response_conn)["errors"]["code"] == "idempotency_unavailable"
  end

  # Verifies replay hook returning {:ok, non_conn} is treated as invalid replay response.
  test "replay_response_fun {:ok, non_conn} returns unavailable response" do
    put_fake_store_state(%{
      claim_result: {:replay, replay_request_atom_keys(731, 200, %{"data" => %{"id" => 4}})}
    })

    opts =
      base_opts(replay_response_fun: fn _conn, _request -> {:ok, :not_a_conn} end)

    assert {:handled, response_conn} =
             run_action_with_opts(opts, fn _ -> flunk("execute_fun should not run") end)

    assert response_conn.status == 503
    assert decoded_json(response_conn)["errors"]["code"] == "idempotency_unavailable"
  end

  # Verifies malformed replay payloads (missing status/body) fail closed.
  test "malformed replay payload falls back to unavailable response" do
    put_fake_store_state(%{
      claim_result:
        {:replay, %{id: 74, status: "succeeded", response_status: nil, response_body: nil}}
    })

    assert {:handled, response_conn} = run_action(fn _ -> flunk("execute_fun should not run") end)

    assert response_conn.status == 503
    assert decoded_json(response_conn)["errors"]["code"] == "idempotency_unavailable"
  end

  # Verifies raised exceptions are persisted as failed and then reraised.
  test "execute_fun raise persists crash payload and reraises original exception" do
    put_fake_store_state(%{
      claim_result: {:execute, processing_request(80)}
    })

    assert_raise RuntimeError, "boom", fn ->
      run_action_result(fn _conn -> raise "boom" end)
    end

    assert_receive {:complete_request_called, %{id: 80}, "failed", 500,
                    %{
                      "errors" => %{
                        "detail" => "Request failed unexpectedly. Please try again.",
                        "code" => "idempotency_execution_failed"
                      }
                    }}
  end

  # Verifies thrown values are persisted as failed and rethrown.
  test "execute_fun throw persists crash payload and rethrows" do
    put_fake_store_state(%{
      claim_result: {:execute, processing_request(81)}
    })

    assert catch_throw(run_action_result(fn _conn -> throw(:boom) end)) == :boom

    assert_receive {:complete_request_called, %{id: 81}, "failed", 500,
                    %{
                      "errors" => %{
                        "detail" => "Request failed unexpectedly. Please try again.",
                        "code" => "idempotency_execution_failed"
                      }
                    }}
  end

  # Verifies exits are persisted as failed and re-raised as exits.
  test "execute_fun exit persists crash payload and exits" do
    put_fake_store_state(%{
      claim_result: {:execute, processing_request(82)}
    })

    assert catch_exit(run_action_result(fn _conn -> exit(:boom) end)) == :boom

    assert_receive {:complete_request_called, %{id: 82}, "failed", 500,
                    %{
                      "errors" => %{
                        "detail" => "Request failed unexpectedly. Please try again.",
                        "code" => "idempotency_execution_failed"
                      }
                    }}
  end

  # Verifies non-conn execute returns are treated as crashes and surfaced clearly.
  test "non-conn execute result persists crash payload and raises clear argument error" do
    put_fake_store_state(%{
      claim_result: {:execute, processing_request(83)}
    })

    assert_raise ArgumentError, ~r/must return %Plug\.Conn\{\}/, fn ->
      run_action_result(fn _conn -> :not_a_conn end)
    end

    assert_receive {:complete_request_called, %{id: 83}, "failed", 500,
                    %{
                      "errors" => %{
                        "detail" => "Request failed unexpectedly. Please try again.",
                        "code" => "idempotency_execution_failed"
                      }
                    }}
  end

  # Verifies crash completion errors never swallow the original crashing exception.
  test "crash completion failure still reraises the original crash" do
    put_fake_store_state(%{
      claim_result: {:execute, processing_request(84)},
      complete_result: {:error, :db_down}
    })

    assert_raise RuntimeError, "boom", fn ->
      run_action_result(fn _conn -> raise "boom" end)
    end
  end

  # Verifies crash_error override customizes persisted crash payload.
  test "crash_error override customizes persisted crash response payload" do
    put_fake_store_state(%{
      claim_result: {:execute, processing_request(85)}
    })

    opts =
      base_opts(
        crash_error: %{
          detail: "Custom crash detail.",
          code: "custom_crash_code",
          metadata: %{
            detail: "ignored",
            code: "ignored",
            retry_after_hint: "5s"
          }
        }
      )

    assert_raise RuntimeError, "boom", fn ->
      run_action_with_opts(opts, fn _conn -> raise "boom" end)
    end

    assert_receive {:complete_request_called, %{id: 85}, "failed", 500,
                    %{
                      "errors" => %{
                        "detail" => "Custom crash detail.",
                        "code" => "custom_crash_code",
                        "retry_after_hint" => "5s"
                      }
                    }}
  end

  # Verifies normal completion failures log and still return the successful execute response.
  test "complete_request error after normal execute returns response and logs completion failure" do
    put_fake_store_state(%{
      claim_result: {:execute, processing_request(63)},
      complete_result: {:error, :db_down}
    })

    log =
      capture_log(fn ->
        assert {:handled, response_conn} =
                 run_action(fn conn ->
                   conn |> put_status(:ok) |> json(%{"data" => %{"ok" => true}})
                 end)

        assert response_conn.status == 200
        assert decoded_json(response_conn) == %{"data" => %{"ok" => true}}
      end)

    assert log =~ "completion failed"

    assert_receive {:complete_request_called, %{id: 63}, "succeeded", 200,
                    %{"data" => %{"ok" => true}}}
  end

  # Verifies iodata response bodies are decoded and persisted as JSON maps.
  test "iodata response body is decoded and persisted" do
    put_fake_store_state(%{
      claim_result: {:execute, processing_request(90)}
    })

    assert {:handled, response_conn} =
             run_action(fn conn ->
               Plug.Conn.send_resp(conn, 200, ["{\"data\":", "{\"ok\":true}", "}"])
             end)

    assert response_conn.status == 200

    assert_receive {:complete_request_called, %{id: 90}, "succeeded", 200,
                    %{
                      "data" => %{"ok" => true}
                    }}
  end

  # Verifies invalid JSON bodies are persisted as empty maps rather than crashing.
  test "invalid JSON response body persists as empty map" do
    put_fake_store_state(%{
      claim_result: {:execute, processing_request(91)}
    })

    assert {:handled, response_conn} =
             run_action(fn conn ->
               Plug.Conn.send_resp(conn, 200, "<<not-json>>")
             end)

    assert response_conn.status == 200
    assert_receive {:complete_request_called, %{id: 91}, "succeeded", 200, %{}}
  end

  # Verifies empty response bodies are tolerated and persisted as empty maps.
  test "empty response body does not crash and persists as empty map" do
    put_fake_store_state(%{
      claim_result: {:execute, processing_request(92)}
    })

    assert {:handled, response_conn} =
             run_action(fn conn ->
               Plug.Conn.send_resp(conn, 204, "")
             end)

    assert response_conn.status == 204
    assert_receive {:complete_request_called, %{id: 92}, "succeeded", 204, %{}}
  end

  # Verifies maybe_run_for_user injects user/scope/payload and executes through maybe_run.
  test "maybe_run_for_user/6 merges user options and runs idempotent flow" do
    put_fake_store_state(%{
      claim_result: {:execute, processing_request(100)}
    })

    conn = conn_with_key("for-user-key")
    execute_fun = fn conn -> conn |> put_status(:ok) |> json(%{"data" => %{"ok" => true}}) end

    assert {:handled, response_conn} =
             Action.maybe_run_for_user(
               conn,
               123,
               "for_user_scope",
               %{"payload" => true},
               execute_fun,
               idempotency_module: FakeIdempotencyModule
             )

    assert response_conn.status == 200
    assert_receive {:request_hash_called, %{"payload" => true}}
    assert_receive {:claim_request_called, 123, "for_user_scope", "for-user-key", @default_hash}
  end

  # Verifies missing :idempotency_module raises a clear configuration error.
  test "missing :idempotency_module option raises ArgumentError" do
    conn = conn_with_key("missing-module")

    assert_raise ArgumentError, ~r/missing required :idempotency_module option/, fn ->
      Action.maybe_run(conn, [user_id: 1, scope: "scope", request_payload: %{}], fn conn ->
        conn
      end)
    end
  end

  # Verifies explicit nil idempotency_module is treated as missing configuration.
  test "explicit nil :idempotency_module raises missing option ArgumentError" do
    conn = conn_with_key("nil-module")

    assert_raise ArgumentError, ~r/missing required :idempotency_module option/, fn ->
      Action.maybe_run(
        conn,
        base_opts(idempotency_module: nil),
        fn execute_conn ->
          execute_conn
        end
      )
    end
  end

  # Verifies required callback contract checks report missing request_hash/1 clearly.
  test "missing request_hash/1 callback raises clear error" do
    conn = conn_with_key("missing-request-hash")

    assert_raise ArgumentError, ~r/must export request_hash\/1/, fn ->
      Action.maybe_run(conn, base_opts(idempotency_module: MissingRequestHashModule), fn conn ->
        conn
      end)
    end
  end

  # Verifies callback validation runs before execute_fun is ever invoked.
  test "missing callback validation happens before execute_fun execution" do
    conn = conn_with_key("missing-claim-request-ordering")

    assert_raise ArgumentError, ~r/must export claim_request\/4/, fn ->
      Action.maybe_run(
        conn,
        base_opts(idempotency_module: MissingClaimRequestModule),
        fn execute_conn ->
          send(self(), :executed)
          execute_conn
        end
      )
    end

    refute_received :executed
  end

  # Verifies required callback contract checks report missing claim_request/4 clearly.
  test "missing claim_request/4 callback raises clear error" do
    conn = conn_with_key("missing-claim-request")

    assert_raise ArgumentError, ~r/must export claim_request\/4/, fn ->
      Action.maybe_run(conn, base_opts(idempotency_module: MissingClaimRequestModule), fn conn ->
        conn
      end)
    end
  end

  # Verifies required callback contract checks report missing complete_request/4 clearly.
  test "missing complete_request/4 callback raises clear error" do
    conn = conn_with_key("missing-complete-request")

    assert_raise ArgumentError, ~r/must export complete_request\/4/, fn ->
      Action.maybe_run(
        conn,
        base_opts(idempotency_module: MissingCompleteRequestModule),
        fn conn ->
          conn
        end
      )
    end
  end

  setup do
    Process.put(@state_key, %{})
    :ok
  end

  defp put_fake_store_state(overrides) when is_map(overrides) do
    Process.put(@state_key, Map.merge(%{}, overrides))
  end

  defp run_action(execute_fun) when is_function(execute_fun, 1) do
    Action.maybe_run(conn_with_key("test-key"), base_opts(), execute_fun)
  end

  defp run_action_result(execute_fun) when is_function(execute_fun, 1) do
    case run_action(execute_fun) do
      {:handled, conn} -> conn
      {:no_key, conn} -> conn
    end
  end

  defp run_action_with_opts(opts, execute_fun) when is_function(execute_fun, 1) do
    Action.maybe_run(conn_with_key("test-key"), opts, execute_fun)
  end

  defp base_opts(overrides \\ []) do
    Keyword.merge(
      [
        idempotency_module: FakeIdempotencyModule,
        user_id: 11,
        scope: "idempotency_kit_test_scope",
        request_payload: %{"a" => 1},
        log_context: "IdempotencyKit test"
      ],
      overrides
    )
  end

  defp decoded_json(%Plug.Conn{resp_body: body}), do: Jason.decode!(body)

  defp conn_with_key(key) do
    Plug.Test.conn("POST", "/test")
    |> put_req_header("accept", "application/json")
    |> put_req_header("idempotency-key", key)
  end

  defp processing_request(id) do
    %{id: id, status: "processing"}
  end

  defp replay_request_atom_keys(id, response_status, response_body) do
    %{
      id: id,
      status: "succeeded",
      response_status: response_status,
      response_body: response_body
    }
  end

  defp replay_request_string_keys(id, response_status, response_body) do
    %{
      "id" => id,
      "status" => "succeeded",
      "response_status" => response_status,
      "response_body" => response_body
    }
  end
end
