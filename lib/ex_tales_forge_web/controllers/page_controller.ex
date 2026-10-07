defmodule TalesForgeWeb.PageController do
  @moduledoc """
  Static pages rendered without LiveView.
  """

  use TalesForgeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
