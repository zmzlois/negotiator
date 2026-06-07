defmodule Negotiator.Repo.Migrations.CreateTranscriptTurns do
  use Ecto.Migration

  def change do
    create table(:transcript_turns) do
      add :call_id, :string, null: false
      add :sequence, :integer
      add :role, :string, null: false
      add :room, :string, null: false
      add :source, :string, null: false
      add :text, :text, null: false
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:transcript_turns, [:call_id])
    create index(:transcript_turns, [:call_id, :sequence])
    create index(:transcript_turns, [:call_id, :role])
  end
end
