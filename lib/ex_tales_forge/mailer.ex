defmodule TalesForge.Mailer do
  @moduledoc """
  Swoosh mailer for outgoing email (admin magic-link logins).
  """

  use Swoosh.Mailer, otp_app: :ex_tales_forge
end
