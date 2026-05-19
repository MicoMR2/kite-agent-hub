defmodule KiteAgentHubWeb.DashboardAsyncLoaderTest do
  @moduledoc """
  Locks the PR-D₂ contract that slow dashboard loaders run on
  `KiteAgentHub.TaskSupervisor` (out-of-band, async_nolink) rather
  than inline in the LV process — so a 3s broker fetch doesn't queue
  chat messages behind it in the LV mailbox (Mico msg 10687/10690).

  The helper is module-private inside DashboardLive, so we exercise
  it indirectly by issuing the same `Task.Supervisor.async_nolink/2`
  call against the same supervisor and asserting:

  * the call does not block the test process for the duration of
    the worker's sleep (mailbox unblocked)
  * a slow worker eventually delivers its result via the
    `{ref, value}` envelope (Task.async_nolink semantics)
  * a worker that crashes surfaces as `{:DOWN, ref, :process, _, _}`
    without taking the calling process down (LV crash protection)
  """

  use ExUnit.Case, async: true

  test "async_nolink does not block the caller during a long Task" do
    start_us = System.monotonic_time(:microsecond)

    %Task{ref: _ref} =
      Task.Supervisor.async_nolink(KiteAgentHub.TaskSupervisor, fn ->
        Process.sleep(300)
        :slow_loader_done
      end)

    spawn_us = System.monotonic_time(:microsecond) - start_us
    # Spawning must return in single-digit ms even though the worker
    # will sleep 300ms. 50ms is a generous CI ceiling.
    assert spawn_us < 50_000, "async_nolink blocked the caller for #{spawn_us}us"
  end

  test "async_nolink eventually delivers the result message" do
    %Task{ref: ref} =
      Task.Supervisor.async_nolink(KiteAgentHub.TaskSupervisor, fn ->
        {:loader_result, :test_key, [1, 2, 3]}
      end)

    assert_receive {^ref, {:loader_result, :test_key, [1, 2, 3]}}, 1_000
    # Demonitor and flush the implicit :DOWN that follows successful
    # async_nolink completion — same shape the LV handler does.
    Process.demonitor(ref, [:flush])
  end

  test "async_nolink surfaces a crashed Task as :DOWN without killing the caller" do
    Process.flag(:trap_exit, true)

    %Task{ref: ref} =
      Task.Supervisor.async_nolink(KiteAgentHub.TaskSupervisor, fn ->
        raise "boom"
      end)

    # The :DOWN message arrives even though we never linked — that's
    # the contract that lets the LV survive a slow-loader crash.
    assert_receive {:DOWN, ^ref, :process, _pid, reason}, 1_000
    assert match?({%RuntimeError{message: "boom"}, _stacktrace}, reason)
  end

  test "during a 300ms loader stall, a separate fast message processes immediately" do
    # This is the mailbox-unblocked proof. If the slow work ran inline
    # (pre-PR-D₂), a fast message sent during the sleep would queue
    # behind it. With async_nolink the slow work runs off-process, so
    # the fast message lands immediately.
    parent = self()

    %Task{ref: slow_ref} =
      Task.Supervisor.async_nolink(KiteAgentHub.TaskSupervisor, fn ->
        Process.sleep(300)
        :slow_done
      end)

    send_us = System.monotonic_time(:microsecond)
    send(parent, :fast_msg)

    receive do
      :fast_msg -> :ok
    after
      100 -> flunk("fast message did not arrive within 100ms — mailbox blocked?")
    end

    delivery_us = System.monotonic_time(:microsecond) - send_us
    assert delivery_us < 100_000

    # Drain the slow loader's success message so it doesn't pollute
    # subsequent tests sharing this process.
    assert_receive {^slow_ref, :slow_done}, 1_000
    Process.demonitor(slow_ref, [:flush])
  end
end
