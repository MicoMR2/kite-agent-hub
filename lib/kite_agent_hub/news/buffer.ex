defmodule KiteAgentHub.News.Buffer do
  @moduledoc """
  Per-symbol ring buffer of recent sanitized news events.

  Subscribes to the `alpaca_stream:news:ALL` PubSub topic on boot,
  runs every incoming event through `KiteAgentHub.News.Sanitizer`,
  and keeps the last `@max_per_symbol` headlines per ticker. Callers
  ask for `recent/1` to populate UI panels (and, eventually, LLM
  prompt context — same sanitized values either way).

  This is the only place that subscribes to the news topic, so we
  pay one fan-in cost regardless of how many LiveViews want to
  display headlines.
  """

  use GenServer

  alias KiteAgentHub.News.Sanitizer

  @pubsub KiteAgentHub.PubSub
  @news_topic "alpaca_stream:news:ALL"
  @max_per_symbol 10

  ## Public API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Return the most recent sanitized headlines for the given symbols,
  newest first, capped at `@max_per_symbol` per symbol. Symbols
  with no buffered headlines yield an empty list — never `nil`.
  """
  @spec recent([String.t()]) :: [Sanitizer.sanitized()]
  def recent(symbols) when is_list(symbols) do
    GenServer.call(__MODULE__, {:recent, symbols})
  catch
    :exit, _ -> []
  end

  def recent(_), do: []

  ## GenServer

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(@pubsub, @news_topic)
    {:ok, %{by_symbol: %{}}}
  end

  @impl true
  def handle_call({:recent, symbols}, _from, state) do
    headlines =
      symbols
      |> Enum.flat_map(fn sym -> Map.get(state.by_symbol, sym, []) end)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.created_at, :desc)
      |> Enum.take(@max_per_symbol)

    {:reply, headlines, state}
  end

  @impl true
  def handle_info(%{type: "n"} = event, state) do
    case Sanitizer.sanitize_event(event) do
      %{symbols: []} ->
        {:noreply, state}

      %{} = sanitized ->
        new_by_symbol =
          Enum.reduce(sanitized.symbols, state.by_symbol, fn sym, acc ->
            existing = Map.get(acc, sym, [])
            Map.put(acc, sym, Enum.take([sanitized | existing], @max_per_symbol))
          end)

        {:noreply, %{state | by_symbol: new_by_symbol}}

      nil ->
        {:noreply, state}
    end
  end

  # Ignore non-news events that may arrive on the same topic if the
  # broadcast surface widens later.
  def handle_info(_other, state), do: {:noreply, state}
end
