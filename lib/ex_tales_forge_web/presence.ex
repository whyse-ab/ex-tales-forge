defmodule TalesForgeWeb.Presence do
  @moduledoc """
  Phoenix Presence on the app's PubSub (`TalesForge.PubSub`): which signed-in
  founders have a page open on this app right now. `TalesForge.Online` tracks
  and reads it; nothing else should call it directly.
  """

  use Phoenix.Presence, otp_app: :ex_tales_forge, pubsub_server: TalesForge.PubSub
end
