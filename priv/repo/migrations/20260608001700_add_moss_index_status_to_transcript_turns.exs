defmodule Negotiator.Repo.Migrations.AddMossIndexStatusToTranscriptTurns do
  use Ecto.Migration

  def change do
    alter table(:transcript_turns) do
      add(:moss_document_id, :string)
      add(:moss_index_status, :string)
      add(:moss_index_error, :text)
      add(:moss_indexed_at, :utc_datetime_usec)
    end

    create(index(:transcript_turns, [:moss_document_id]))
    create(index(:transcript_turns, [:moss_index_status]))
  end
end
