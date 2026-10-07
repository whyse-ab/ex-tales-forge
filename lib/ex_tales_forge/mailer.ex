defmodule TalesForge.Mailer do
  @moduledoc """
  Swoosh mailer for outgoing email. Nothing sends mail since the admin
  magic-link logins were removed on 2026-10-07.
  """

  use Swoosh.Mailer, otp_app: :ex_tales_forge
end
