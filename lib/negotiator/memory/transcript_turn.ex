defmodule Negotiator.TranscriptTurn do
  @moduledoc """
  durable sqlite row for one final transcript turn.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "transcript_turns" do
    field(:call_id, :string)
    field(:sequence, :integer)
    field(:role, :string)
    field(:room, :string)
    field(:source, :string)
    field(:text, :string)
    field(:investor_name, :string)
    field(:investor_number, :string)
    field(:investor_firm, :string)
    field(:moss_document_id, :string)
    field(:moss_index_status, :string)
    field(:moss_index_error, :string)
    field(:moss_indexed_at, :utc_datetime_usec)
    field(:metadata, :map, default: %{})
    field(:occurred_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  validates one transcript turn before it is written to sqlite.
  """
  def changeset(turn, attrs) do
    turn
    |> cast(attrs, [
      :call_id,
      :sequence,
      :role,
      :room,
      :source,
      :text,
      :investor_name,
      :investor_number,
      :investor_firm,
      :moss_document_id,
      :moss_index_status,
      :moss_index_error,
      :moss_indexed_at,
      :metadata,
      :occurred_at
    ])
    |> validate_required([:call_id, :role, :room, :source, :text, :metadata, :occurred_at])
  end
end
