defmodule InfluxTelemetryReporterTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias InfluxTelemetryReporter, as: SUT
  alias Telemetry.Metrics

  describe "start_link/1" do
    test "with valid arguments" do
      SUT.start_link(metrics: [], influx_writer: fn _, _, _ -> :ok end)
    end

    test "has a mandatory influx_writer option" do
      assert_raise ArgumentError,
                   "the :influx_writer option is required by InfluxTelemetryReporter",
                   fn ->
                     SUT.start_link([])
                   end
    end

    test "with invalid influx_writer option" do
      assert_raise ArgumentError,
                   "InfluxTelemetryReporter requires :influx_writer to be a function with 3 arity",
                   fn ->
                     SUT.start_link(influx_writer: :boo)
                   end
    end

    test "has a mandatory metrics option" do
      assert_raise ArgumentError,
                   "the :metrics option is required by InfluxTelemetryReporter",
                   fn ->
                     SUT.start_link(influx_writer: fn _, _, _ -> :ok end)
                   end
    end
  end

  describe "init/2" do
    test "attach to telemetry event once for duplicated metrics with same event name" do
      assert :telemetry.list_handlers([:my_event, :request, :stop]) == []

      metrics = [
        Metrics.summary("my_event.request.stop.duration",
          unit: {:native, :millisecond}
        ),
        Metrics.counter("my_event.request.stop.duration",
          unit: {:native, :millisecond}
        )
      ]

      assert {:ok, _} = SUT.init({metrics, fn _, _, _ -> :ok end})
      assert [_] = :telemetry.list_handlers([:my_event, :request, :stop])
    end

    test "returns non-duplicate list of events" do
      metrics = [
        Metrics.summary("phoenix.endpoint.stop.duration",
          unit: {:native, :millisecond}
        ),
        Metrics.counter("phoenix.endpoint.stop.duration",
          unit: {:native, :millisecond}
        ),
        Metrics.counter("phoenix.endpoint.start.time",
          unit: {:native, :millisecond}
        )
      ]

      assert SUT.init({metrics, fn _, _, _ -> :ok end}) ==
               {:ok, [[:phoenix, :endpoint, :start], [:phoenix, :endpoint, :stop]]}
    end
  end

  describe "telemetry callback" do
    setup do
      test_pid = self()
      self_writer = fn event, value, tags -> send(test_pid, {event, value, tags}) end

      metrics = [
        Metrics.counter("my_event.request.stop.duration", tags: [:my_tag])
      ]

      %{influx_writer: self_writer, metrics: metrics}
    end

    test "reports an event to influxdb", %{influx_writer: influx_writer, metrics: metrics} do
      assert {:ok, _} = SUT.start_link(metrics: metrics, influx_writer: influx_writer)
      :telemetry.execute([:my_event, :request, :stop], %{duration: 1}, %{my_tag: "hello"})
      assert_receive {"my_event.request.stop.duration", [my_tag: "hello"], 1}
    end

    test "does not report when the measurement is nil", %{
      influx_writer: influx_writer,
      metrics: metrics
    } do
      assert {:ok, _} = SUT.start_link(metrics: metrics, influx_writer: influx_writer)
      :telemetry.execute([:my_event, :request, :stop], %{}, %{my_tag: "hello"})
      refute_received {"my_event.request.stop", [my_tag: "hello"], nil}
    end

    test "reports only when keep function allows it", %{influx_writer: influx_writer} do
      metrics = [
        Metrics.counter("my_event.request.stop.duration",
          keep: fn metadata -> match?(%{keep_it: true}, metadata) end
        )
      ]

      assert {:ok, _} = SUT.start_link(metrics: metrics, influx_writer: influx_writer)
      :telemetry.execute([:my_event, :request, :stop], %{duration: 1}, %{keep_it: false})
      refute_received {"my_event.request.stop.duration", [], 1}

      :telemetry.execute([:my_event, :request, :stop], %{duration: 1}, %{keep_it: true})
      assert_receive {"my_event.request.stop.duration", [], 1}
    end

    test "Does not call measurement/1 function if keep returns false", %{
      influx_writer: influx_writer
    } do
      test_pid = self()

      metrics = [
        Metrics.counter("my_event.request.stop.duration",
          keep: fn metadata -> match?(%{keep_it: true}, metadata) end,
          measurement: fn measurement ->
            send(test_pid, {:measurement_function_called, measurement})
          end
        )
      ]

      assert {:ok, _} = SUT.start_link(metrics: metrics, influx_writer: influx_writer)
      :telemetry.execute([:my_event, :request, :stop], %{duration: 1}, %{keep_it: false})
      refute_received {:measurement_function_called, _}

      :telemetry.execute([:my_event, :request, :stop], %{duration: 1}, %{keep_it: true})
      assert_receive {:measurement_function_called, %{duration: 1}}
    end

    test "Does not call measurement/2 function if keep returns false", %{
      influx_writer: influx_writer
    } do
      test_pid = self()

      metrics = [
        Metrics.counter("my_event.request.stop.duration",
          keep: fn metadata -> match?(%{keep_it: true}, metadata) end,
          measurement: fn measurement, metadata ->
            send(test_pid, {:measurement_function_called, measurement, metadata})
          end
        )
      ]

      assert {:ok, _} = SUT.start_link(metrics: metrics, influx_writer: influx_writer)
      :telemetry.execute([:my_event, :request, :stop], %{duration: 1}, %{keep_it: false})
      refute_received {:measurement_function_called, _, _}

      :telemetry.execute([:my_event, :request, :stop], %{duration: 1}, %{keep_it: true})
      assert_receive {:measurement_function_called, %{duration: 1}, %{keep_it: true}}
    end

    test "Does not call tag_values/1 function if keep returns false", %{
      influx_writer: influx_writer
    } do
      test_pid = self()

      metrics = [
        Metrics.counter("my_event.request.stop.duration",
          keep: fn metadata -> match?(%{keep_it: true}, metadata) end,
          tag_values: fn metadata ->
            send(test_pid, {:tag_values, metadata})
            %{}
          end
        )
      ]

      assert {:ok, _} = SUT.start_link(metrics: metrics, influx_writer: influx_writer)
      :telemetry.execute([:my_event, :request, :stop], %{duration: 1}, %{keep_it: false})
      refute_received {:tag_values, _}

      :telemetry.execute([:my_event, :request, :stop], %{duration: 1}, %{keep_it: true})
      assert_receive {:tag_values, %{keep_it: true}}
    end

    test "Does not call tag_values/1 function if measurement is nil", %{
      influx_writer: influx_writer
    } do
      test_pid = self()

      metrics = [
        Metrics.counter("my_event.request.stop.duration",
          tag_values: fn metadata ->
            send(test_pid, {:tag_values, metadata})
            %{}
          end
        )
      ]

      assert {:ok, _} = SUT.start_link(metrics: metrics, influx_writer: influx_writer)
      :telemetry.execute([:my_event, :request, :stop], %{}, %{})
      refute_received {:tag_values, _}

      :telemetry.execute([:my_event, :request, :stop], %{duration: 1}, %{keep_it: true})
      assert_receive {:tag_values, %{keep_it: true}}
    end

    test "reports measurement based on measurement/1 function", %{influx_writer: influx_writer} do
      measurement_convertor = fn measurements -> measurements.duration / 60 end

      metrics = [
        Metrics.counter("my_event.request.stop.duration",
          measurement: measurement_convertor
        )
      ]

      assert {:ok, _} = SUT.start_link(metrics: metrics, influx_writer: influx_writer)
      :telemetry.execute([:my_event, :request, :stop], %{duration: 120})
      assert_receive {"my_event.request.stop.duration", [], 2.0}
    end

    test "reports measurement based on measurement/2 function", %{influx_writer: influx_writer} do
      measurement_multiplier = fn measurements, metadata ->
        measurements.duration * metadata.scale
      end

      metrics = [
        Metrics.counter("my_event.request.stop.duration",
          measurement: measurement_multiplier
        )
      ]

      assert {:ok, _} = SUT.start_link(metrics: metrics, influx_writer: influx_writer)
      :telemetry.execute([:my_event, :request, :stop], %{duration: 120}, %{scale: 1000})
      assert_receive {"my_event.request.stop.duration", [], 120_000}
    end

    test "logs the error when is not able to write to influx_writer", %{metrics: metrics} do
      capture_runtime_error = fn ->
        faulty_writer = fn _, _, _ -> raise RuntimeError end
        assert {:ok, _} = SUT.start_link(metrics: metrics, influx_writer: faulty_writer)
        :telemetry.execute([:my_event, :request, :stop], %{duration: 120}, %{scale: 1000})
      end

      assert capture_log(capture_runtime_error) =~ "RuntimeError"
    end

    test "uses tag_values function to add tags based on data in event's metadata", %{
      influx_writer: influx_writer
    } do
      metrics = [
        Metrics.summary("my_client.request.stop", [
          {:event_name, [:my_client, :request, :stop]},
          {:measurement, :duration},
          {:tags, [:http_status_code]},
          {:tag_values,
           fn meta ->
             case meta.response do
               {:ok, %{status_code: status_code}} -> %{http_status_code: status_code}
               {:error, _} -> %{http_status_code: 0}
             end
           end}
        ])
      ]

      assert {:ok, _} = SUT.start_link(metrics: metrics, influx_writer: influx_writer)

      :telemetry.execute([:my_client, :request, :stop], %{duration: 120}, %{
        response: {:ok, %{status_code: 200}}
      })

      assert_receive {"my_client.request.stop", [http_status_code: 200], 120}
    end
  end
end
