defmodule ExSentry.Client do
  require Logger
  import ExSentry.Utils, only: [safely_do: 1]

  @moduledoc false

  # A GenServer which handles the capture of message/exception information
  # and its submission to Sentry.  Not intended for end users' direct usage;
  # use `ExSentry` as the primary interface instead.

  ## TODO 1.0 make this a regular map rather than a struct
  defmodule State do
    @moduledoc false

    defstruct dsn: nil,
              url: nil,
              key: nil,
              secret: nil,
              opts: nil,
              project_id: nil,
              version: nil,
              status: nil,
              hackney_connection: nil  ## TODO deprecated, remove in 1.0
  end

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, opts)
  end

  @doc ~S"""
  GenServer callback to initialize this server.

  Pass `args[:dsn]`, set environment variable `SENTRY_DSN`, or
  add `config :exsentry, dsn: "your-dsn-here"` to `config.exs` to
  set Sentry DSN (required).  Passing a blank string `""`
  as DSN will disable HTTP requests, as will `Mix.env == :test`.

  Pass a keyword list as `args[:opts]` in order to send these options
  with each request to Sentry.
  """
  def init(args \\ %{}) do
    dsn = Map.get(args, :dsn) ||
          System.get_env("SENTRY_DSN") ||
          Application.get_env(:exsentry, :dsn)
    cond do
      dsn == "" ->
        {:ok, %State{status: :disabled}}
      is_nil(dsn) ->
        {:ok, %State{status: :no_dsn}}
      true ->
        init_from_dsn_and_opts(dsn, Map.get(args, :opts))
    end
  end

  defp init_from_dsn_and_opts(dsn, opts) do
    case Fuzzyurl.from_string(dsn) do
      nil ->
        raise "DSN couldn't be parsed"
      fu ->
        project_id = fu.path |> String.split("/") |> List.last
        post_fu = %Fuzzyurl{
          protocol: fu.protocol,
          hostname: fu.hostname,
          port: fu.port,
          path: "/api/#{project_id}/store/"
        }
        version = case Application.get_env(:exsentry, :otp_app) do
          nil -> "0.0.0"
          app -> ExSentry.Utils.version(app) || "0.0.0"
        end

        {:ok, %State{
          dsn: dsn,
          key: fu.username,
          secret: fu.password,
          opts: opts,
          url: post_fu |> Fuzzyurl.to_string,
          project_id: project_id,
          version: ExSentry.Utils.version,
          status: :ready,
          hackney_connection: nil, ## TODO deprecated, remove in 1.0
        }}
    end
  end

  def handle_cast(_, %State{status: :disabled}=state) do
    {:noreply, state}
  end

  def handle_cast(_, %State{status: :no_dsn}) do
    raise "Sentry DSN is not configured.  " <>
          "Add `config :exsentry, dsn: \"your-dsn-here\"` to `config.exs`."
  end


  def handle_cast({:capture_exception, exception, trace, attrs}, %State{}=state) do
    opts = state.opts || []
    capture_exception(exception, trace, opts ++ attrs, state)
    {:noreply, state}
  end

  def handle_cast({:capture_message, message, attrs}, %State{}=state) do
    opts = state.opts || []
    capture_message(message, opts ++ attrs, state)
    {:noreply, state}
  end


  @spec capture_exception(Exception.t, [tuple], [atom: any], %State{}) :: pid
  defp capture_exception(exception, trace, opts, state) do
    safely_do fn ->
      opts
      |> Dict.put(:message, Exception.message(exception))
      |> Dict.put(:stacktrace, ExSentry.Model.Stacktrace.from_stacktrace(trace))
      |> ExSentry.Model.Payload.from_opts
      |> send_payload(state)
    end
  end

  @spec capture_message(String.t, [atom: any], %State{}) :: pid
  defp capture_message(message, opts, state) do
    safely_do fn ->
      opts
      |> Dict.put(:message, message)
      |> ExSentry.Model.Payload.from_opts
      |> send_payload(state)
    end
  end

  @spec send_payload(map, %State{}) :: pid
  defp send_payload(payload, state) do
    safely_do fn ->
      body = payload
             |> Map.from_struct
             |> ExSentry.Utils.strip_nils_from_map
             |> Poison.encode!
      headers = [
        {"X-Sentry-Auth", ExSentry.Model.Payload.get_auth_header_value(state)},
        {"Content-Type", "application/json"}
      ]

      :hackney.request(:post, state.url, headers, body)
    end
  end
end


