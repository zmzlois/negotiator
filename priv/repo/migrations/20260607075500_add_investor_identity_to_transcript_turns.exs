defmodule Negotiator.Repo.Migrations.AddInvestorIdentityToTranscriptTurns do
  use Ecto.Migration

  def change do
    alter table(:transcript_turns) do
      add :investor_name, :string
      add :investor_number, :string
      add :investor_firm, :string
    end

    create index(:transcript_turns, [:investor_name])
    create index(:transcript_turns, [:investor_number])
    create index(:transcript_turns, [:investor_firm])
  end
end
