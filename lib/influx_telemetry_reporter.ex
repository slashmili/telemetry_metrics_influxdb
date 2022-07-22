# This module is based on [Telemetry.Metrics.ConsoleReporter](https://github.com/beam-telemetry/telemetry_metrics/blob/main/lib/telemetry_metrics/console_reporter.ex) which is released under Apache License 2.0 
defmodule InfluxTelemetryReporter do
  @moduledoc """
  A reporter that writes the events in the influx_writer. 


    * You have to bring your own InfluxDB writer when using this lib. We suggest [fluxter](https://hex.pm/packages/fluxter).
    * This Reporter ignores the metric type(summary, count and etc) and simply writes the report to influxdb.

  This GenServer could be used in a Supervisor like:

      defmodule MyApp.Telemetry do
        use Supervisor
        import Telemetry.Metrics

        def start_link(arg) do
          Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
        end

        @impl true
        def init(_arg) do
          children = [
            {InfluxTelemetryReporter, metrics: metrics(), influx_writer: &MyApp.Fluxter.write/3}
          ]

          Supervisor.init(children, strategy: :one_for_one)
        end

        def metrics do
          [
            summary("vm.memory.total",
              unit: {:byte, :kilobyte},
              description: "measurement of the memory used by the Erlang VM"
            )
          ]
        end

  by that it attaches itself to the events described in the metric and report the events
  to influxdb. Read more about metrics at https://hexdocs.pm/telemetry_metrics/Telemetry.Metrics.html
  """
  use GenServer
  require Logger

  @doc """
  Starts the GenServer and attaches to the telemetry events

  Expected options: 

    * `:influx_writer`: a function that implements `c:Fluxter.write/3` callback
    * `:metrics`: list of metrics `t:Telemetry.Metrics.t/0`
  """
  def start_link(opts) do
    server_opts = Keyword.take(opts, [:name])

    influx_writer =
      opts[:influx_writer] ||
        raise ArgumentError, "the :influx_writer option is required by #{inspect(__MODULE__)}"

    is_function(influx_writer, 3) ||
      raise ArgumentError,
            "#{inspect(__MODULE__)} requires :influx_writer to be a function with 3 arity"

    metrics =
      opts[:metrics] ||
        raise ArgumentError, "the :metrics option is required by #{inspect(__MODULE__)}"

    GenServer.start_link(__MODULE__, {metrics, influx_writer}, server_opts)
  end

  @impl true
  def init({metrics, influx_writer}) do
    Process.flag(:trap_exit, true)
    groups = Enum.group_by(metrics, & &1.event_name)

    for {event, metrics} <- groups do
      id = {__MODULE__, event, self()}
      :telemetry.attach(id, event, &__MODULE__.handle_event/4, {metrics, influx_writer})
    end

    {:ok, Map.keys(groups)}
  end

  @impl true
  def terminate(_, events) do
    for event <- events do
      :telemetry.detach({__MODULE__, event, self()})
    end

    :ok
  end

  # This function must follow logics as described:
  # https://hexdocs.pm/telemetry_metrics/writing_reporters.html#reacting-to-events
  @doc false
  def handle_event(_event_name, measurements, metadata, {metrics, influx_writer}) do
    for %{} = metric <- metrics do
      event_name_in_string = Enum.join(metric.name, ".")

      try do
        measurement = extract_measurement(metric, measurements, metadata)
        tags = extract_tags(metric, metadata)

        cond do
          is_nil(measurement) ->
            :skip

          not keep?(metric, metadata) ->
            :skip

          true ->
            influx_writer.(
              event_name_in_string,
              Keyword.new(tags),
              measurement
            )
        end
      rescue
        e ->
          Logger.error([
            "Could not format metric #{inspect(metric)}\n",
            Exception.format(:error, e, __STACKTRACE__)
          ])
      end
    end
  end

  defp keep?(%{keep: nil}, _metadata), do: true
  defp keep?(metric, metadata), do: metric.keep.(metadata)

  defp extract_measurement(metric, measurements, metadata) do
    case metric.measurement do
      fun when is_function(fun, 2) -> fun.(measurements, metadata)
      fun when is_function(fun, 1) -> fun.(measurements)
      key -> measurements[key]
    end
  end

  defp extract_tags(metric, metadata) do
    tag_values = metric.tag_values.(metadata)
    Map.take(tag_values, metric.tags)
  end
end
