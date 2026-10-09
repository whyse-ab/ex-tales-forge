defmodule TalesForge.AppRolePeerTokenTest do
  use ExUnit.Case, async: false

  alias TalesForge.AppRole

  setup do
    previous = Application.get_env(:ex_tales_forge, :costs_peer)
    on_exit(fn -> Application.put_env(:ex_tales_forge, :costs_peer, previous || []) end)
  end

  test "peer_token/0 is the trimmed shared token, nil when unset or blank" do
    Application.put_env(:ex_tales_forge, :costs_peer, token: "  s3cret \n")
    assert AppRole.peer_token() == "s3cret"
    assert TalesForge.Costs.Peer.token() == "s3cret"

    Application.put_env(:ex_tales_forge, :costs_peer, token: "   ")
    assert AppRole.peer_token() == nil

    Application.put_env(:ex_tales_forge, :costs_peer, [])
    assert AppRole.peer_token() == nil
  end
end
