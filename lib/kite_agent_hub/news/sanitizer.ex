defmodule KiteAgentHub.News.Sanitizer do
  @moduledoc """
  Strip + cap untrusted news event fields before they reach a UI
  template or a downstream LLM-prompt injector.

  CyberSec msg 7944: news headlines are an inbound prompt-injection
  vector. Every field that originated outside the application (the
  Alpaca news WebSocket payload) MUST go through this module before
  it hits the agent context surface. The contract:

    * Strip HTML tags (no `<script>`, `<img onerror=...>`, no
      arbitrary attribute that could embed an instruction).
    * Strip control characters and zero-width characters (Unicode
      tagging, RTL overrides, etc.) that LLMs render as invisible
      input.
    * Hard byte cap per field — a 4 KB headline is not a real
      headline, it's a payload. Cap at 256 bytes.
    * Drop fields that fail to decode as UTF-8.

  This is a pure data transform; no side effects.
  """

  @max_headline_bytes 256
  @max_summary_bytes 1024

  @typedoc "Sanitized news event suitable for UI rendering or prompt injection."
  @type sanitized :: %{
          id: String.t() | nil,
          symbols: [String.t()],
          headline: String.t(),
          summary: String.t(),
          author: String.t() | nil,
          created_at: String.t() | nil,
          url: String.t() | nil
        }

  @doc """
  Sanitize a single news event from `AlpacaStream`'s `:news` dispatch.
  Returns a map with all string fields cleaned + capped, or `nil` if
  the input is unrecognisable.
  """
  @spec sanitize_event(map()) :: sanitized() | nil
  def sanitize_event(%{} = event) do
    %{
      id: clean_optional(event[:id] || event["id"], 64),
      symbols: clean_symbol_list(event[:symbols] || event["symbols"]),
      headline: clean_string(event[:headline] || event["headline"], @max_headline_bytes),
      summary: clean_string(event[:summary] || event["summary"], @max_summary_bytes),
      author: clean_optional(event[:author] || event["author"], 128),
      created_at: clean_optional(event[:created_at] || event["created_at"], 64),
      url: clean_optional(event[:url] || event["url"], 512)
    }
  end

  def sanitize_event(_), do: nil

  @doc """
  Strip HTML tags + control characters + zero-width Unicode from a
  string, then truncate to `max_bytes` bytes (with an ellipsis if the
  truncation actually removed characters). Returns `""` on anything
  that isn't a valid binary.
  """
  @spec clean_string(any(), pos_integer()) :: String.t()
  def clean_string(nil, _max), do: ""

  def clean_string(value, max_bytes) when is_binary(value) and is_integer(max_bytes) do
    if String.valid?(value) do
      value
      |> strip_html()
      |> strip_unsafe_unicode()
      |> String.trim()
      |> truncate_bytes(max_bytes)
    else
      ""
    end
  end

  def clean_string(_, _), do: ""

  defp clean_optional(value, max), do: clean_string(value, max) |> nil_if_empty()

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s), do: s

  defp clean_symbol_list(list) when is_list(list) do
    list
    |> Enum.map(&clean_string(&1, 32))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp clean_symbol_list(_), do: []

  # Drop tags + their content for `<script>` / `<style>`; for everything
  # else strip the angle brackets + attributes but keep inner text.
  # We deliberately do NOT use a real HTML parser here — the input is
  # always small, and a regex pass + control-char strip is enough for
  # safe rendering and safe LLM injection. Anything more sophisticated
  # would just expand the trust surface.
  defp strip_html(s) do
    s
    |> String.replace(~r/<script[\s\S]*?<\/script>/i, "")
    |> String.replace(~r/<style[\s\S]*?<\/style>/i, "")
    |> String.replace(~r/<[^>]+>/, "")
    |> decode_basic_entities()
  end

  defp decode_basic_entities(s) do
    s
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
  end

  # Strip ASCII control bytes + Unicode tagging / RTL-override
  # blocks that LLMs treat as instructions but humans never see.
  defp strip_unsafe_unicode(s) do
    s
    |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F]/, "")
    |> String.replace(~r/[\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}\x{E0000}-\x{E007F}]/u, "")
  end

  defp truncate_bytes(s, max) do
    if byte_size(s) <= max do
      s
    else
      # `String.slice/2` works on graphemes; we need byte truncation
      # to enforce the cap, then trim back to the nearest valid
      # codepoint so we don't emit invalid UTF-8.
      <<head::binary-size(max), _rest::binary>> = s
      head |> trim_invalid_utf8() |> Kernel.<>("…")
    end
  end

  # If the byte-truncated head ends mid-codepoint, drop the trailing
  # incomplete bytes until we land on a valid binary.
  defp trim_invalid_utf8(s) do
    if String.valid?(s) do
      s
    else
      case s do
        "" -> ""
        _ -> trim_invalid_utf8(binary_part(s, 0, byte_size(s) - 1))
      end
    end
  end
end
