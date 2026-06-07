defmodule Negotiator.Knowledge.Unsiloed do
  @moduledoc """
  converts unsiloed parser exports into moss documents.
  """

  alias Moss.DocumentInfo
  alias Negotiator.Prediction

  @default_min_words 40
  @default_min_page 8
  @card_min_words 55
  @card_max_chars 1_200

  @book_titles %{
    "crucial-convo" => "Crucial Conversations",
    "getting-to-yes" => "Getting to Yes",
    "never-split-the-difference" => "Never Split the Difference"
  }

  @card_keywords [
    "ask",
    "question",
    "listen",
    "label",
    "mirror",
    "empathy",
    "silence",
    "interest",
    "option",
    "criteria",
    "standard",
    "fair",
    "safe",
    "dialogue",
    "no",
    "yes",
    "calibrated",
    "anchor",
    "concession",
    "agreement",
    "objection",
    "control",
    "trust"
  ]

  @doc """
  loads all unsiloed json exports in a directory as moss documents.
  """
  def load_directory!(dir, opts \\ []) do
    dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(&load_file!(&1, opts))
  end

  @doc """
  loads one unsiloed json export as moss documents.
  """
  def load_file!(path, opts \\ []) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> documents(path, opts)
  end

  @doc """
  converts one decoded unsiloed export into moss documents.
  """
  def documents(export, path, opts \\ []) when is_map(export) do
    slug = book_slug(path)
    title = Map.get(@book_titles, slug, titleize(slug))
    min_words = Keyword.get(opts, :min_words, @default_min_words)
    min_page = Keyword.get(opts, :min_page, @default_min_page)
    include_raw? = Keyword.get(opts, :include_raw?, true)
    include_cards? = Keyword.get(opts, :include_cards?, true)

    export
    |> Map.get("chunks", [])
    |> Enum.with_index()
    |> Enum.flat_map(fn {chunk, index} ->
      text = clean_text(chunk["embed"] || "")

      if Prediction.word_count(text) < min_words or not useful_chunk?(chunk, text, min_page) do
        []
      else
        raw_doc =
          if include_raw? do
            [raw_document(export, chunk, text, slug, title, path, index)]
          else
            []
          end

        card_doc =
          if include_cards? and card_candidate?(text) do
            [card_document(export, chunk, text, slug, title, path, index)]
          else
            []
          end

        raw_doc ++ card_doc
      end
    end)
  end

  @doc """
  returns a compact summary for task output.
  """
  def summarize(docs) do
    docs
    |> Enum.group_by(fn %DocumentInfo{metadata: metadata} ->
      {metadata["book"], metadata["kind"]}
    end)
    |> Enum.map(fn {{book, kind}, docs} -> %{book: book, kind: kind, count: length(docs)} end)
    |> Enum.sort_by(&{&1.book, &1.kind})
  end

  defp raw_document(export, chunk, text, slug, title, path, index) do
    %DocumentInfo{
      id: "#{slug}:raw:#{padded_index(index)}",
      text: text,
      metadata: base_metadata(export, chunk, slug, title, path, index, "raw_chunk")
    }
  end

  defp card_document(export, chunk, text, slug, title, path, index) do
    %DocumentInfo{
      id: "#{slug}:card:#{padded_index(index)}",
      text: card_text(text),
      metadata:
        export
        |> base_metadata(chunk, slug, title, path, index, classify_card(text))
        |> Map.put("derived_from", "#{slug}:raw:#{padded_index(index)}")
    }
  end

  defp base_metadata(export, chunk, slug, title, path, index, kind) do
    pages = pages(chunk)

    stringify_metadata(%{
      "source" => "unsiloed",
      "book" => title,
      "book_slug" => slug,
      "kind" => kind,
      "mode" => "negotiation_briefing",
      "parser_file" => path,
      "source_file" => export["file_name"],
      "chunk_id" => chunk["chunk_id"],
      "chunk_index" => index,
      "chunk_length" => chunk["chunk_length"],
      "page_start" => List.first(pages),
      "page_end" => List.last(pages),
      "page_count" => export["page_count"],
      "total_chunks" => export["total_chunks"],
      "segment_types" => segment_types(chunk)
    })
  end

  defp stringify_metadata(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {key, metadata_value(value)} end)
  end

  defp metadata_value(values) when is_list(values), do: Enum.map_join(values, ",", &to_string/1)
  defp metadata_value(value), do: to_string(value)

  defp card_candidate?(text) do
    downcased = String.downcase(text)

    Prediction.word_count(text) >= @card_min_words and
      Enum.any?(@card_keywords, &String.contains?(downcased, &1))
  end

  defp useful_chunk?(chunk, text, min_page) do
    downcased = text |> String.downcase() |> String.replace(~r/\s+/u, " ")
    types = segment_types(chunk)
    page_start = chunk |> pages() |> List.first()

    cond do
      is_integer(page_start) and page_start < min_page ->
        false

      types != [] and Enum.all?(types, &(&1 == "Picture")) ->
        false

      String.contains?(downcased, front_matter_markers()) ->
        false

      table_of_contents_fragment?(downcased) ->
        false

      true ->
        true
    end
  end

  defp table_of_contents_fragment?(text) do
    ~r/ch\s*\.\s*\d+/u
    |> Regex.scan(text)
    |> length()
    |> Kernel.>=(3)
  end

  defp front_matter_markers do
    [
      "all rights reserved",
      "acknowledgments",
      "best - seller",
      "books by",
      "contents foreword",
      "copies sold",
      "copyright",
      "cover design",
      "foreword",
      "isbn",
      "penguin books",
      "praise for",
      "table of contents"
    ]
  end

  defp classify_card(text) do
    downcased = String.downcase(text)

    cond do
      String.contains?(downcased, ["avoid", "don't", "do not", "never "]) ->
        "anti_pattern"

      String.contains?(downcased, ["say ", "phrase", "\"", "ask "]) ->
        "phrase"

      String.contains?(downcased, ["step", "method", "technique", "tactic", "question"]) ->
        "tactic"

      true ->
        "principle"
    end
  end

  defp card_text(text) do
    text
    |> sentences()
    |> Enum.take(4)
    |> Enum.join(" ")
    |> String.slice(0, @card_max_chars)
    |> String.trim()
  end

  defp sentences(text) do
    text
    |> String.split(~r/(?<=[.!?])\s+/u, trim: true)
    |> Enum.reject(&(Prediction.word_count(&1) < 4))
  end

  defp clean_text(text) do
    text
    |> to_string()
    |> String.replace(~r/!\[([^\]]*)\]\([^\)]*\)/u, "\\1")
    |> String.replace(~r/\[([^\]]+)\]\([^\)]*\)/u, "\\1")
    |> String.replace(~r/^\s{0,3}\#{1,6}\s*/mu, "")
    |> String.replace(~r/https?:\/\/\S+/u, "")
    |> String.replace(~r/[ \t]+/u, " ")
    |> String.replace(~r/\n{3,}/u, "\n\n")
    |> String.trim()
  end

  defp pages(chunk) do
    chunk
    |> Map.get("segments", [])
    |> Enum.map(& &1["page_number"])
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp segment_types(chunk) do
    chunk
    |> Map.get("segments", [])
    |> Enum.map(& &1["segment_type"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp book_slug(path) do
    path
    |> Path.basename(".json")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  defp titleize(slug) do
    slug
    |> String.split("-", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp padded_index(index), do: index |> Integer.to_string() |> String.pad_leading(4, "0")
end
