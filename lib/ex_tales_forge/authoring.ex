defmodule TalesForge.Authoring do
  @moduledoc """
  Ash domain for pre-play authored content (Adventures, Roster, NPC definitions, Locations).
  Per AGENTS.md: Ash owns content before play; Jido + Oban own during play.
  """

  use Ash.Domain, otp_app: :ex_tales_forge

  resources do
    resource TalesForge.Authoring.Adventure
    resource TalesForge.Authoring.Location
    resource TalesForge.Authoring.NpcDefinition

    # RosterCharacter + relationships belong with pack roster/ import, not this domain yet.
  end
end
