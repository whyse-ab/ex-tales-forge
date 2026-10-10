defmodule TalesForgeWeb.Plugs.TelemetryChrome do
  @moduledoc """
  The admin chrome around LiveDashboard at `/admin/operate/telemetry`. The
  dashboard has its own layout, so this plug adds two things:

  1. `GET /admin/operate/telemetry` goes to `/admin/operate/telemetry/home`
     and keeps the query string. (LiveDashboard's own redirect drops it.)
  2. Each HTML page of the dashboard gets a breadcrumb bar at the top of the
     body: "Admin › Operate › Telemetry", with links back to `/admin`. The bar
     is outside the LiveView container, so it stays when the dashboard
     changes page.
  """

  @behaviour Plug

  import Plug.Conn

  @base "/admin/operate/telemetry"

  @crumbs ~s(<nav id="telemetry-crumbs" aria-label="Breadcrumb" ) <>
            ~s(style="font:14px/1.4 system-ui,sans-serif;padding:10px 16px;) <>
            ~s(background:#f6f1e7;border-bottom:1px solid #ddd2bf;color:#5b5348">) <>
            ~s(<a href="/admin" style="color:#8a3b12;font-weight:600;display:inline-block;min-height:44px;line-height:44px;padding:0 4px">← Admin</a>) <>
            ~s( › <a href="/admin#section-operate" style="color:#8a3b12;display:inline-block;min-height:44px;line-height:44px;padding:0 4px">Operate</a>) <>
            ~s( › <span aria-current="page">Telemetry</span></nav>)

  @impl true
  @spec init(term()) :: term()
  def init(opts), do: opts

  @impl true
  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(%Plug.Conn{method: "GET", request_path: path} = conn, _opts)
      when path in [@base, @base <> "/"] do
    to =
      if conn.query_string == "",
        do: @base <> "/home",
        else: @base <> "/home?" <> conn.query_string

    conn
    |> Phoenix.Controller.redirect(to: to)
    |> halt()
  end

  def call(conn, _opts), do: register_before_send(conn, &add_crumbs/1)

  @doc """
  Adds the breadcrumb bar after the opening `<body>` tag of an HTML response
  with status 200. Other responses stay the same.

      iex> conn = %Plug.Conn{status: 200, resp_body: "<html><body class=\\"x\\"><main></main></body></html>",
      ...>   resp_headers: [{"content-type", "text/html; charset=utf-8"}]}
      iex> TalesForgeWeb.Plugs.TelemetryChrome.add_crumbs(conn).resp_body =~ ~s(<body class="x"><nav id="telemetry-crumbs")
      true
  """
  @spec add_crumbs(Plug.Conn.t()) :: Plug.Conn.t()
  def add_crumbs(%Plug.Conn{status: 200} = conn) do
    with [type | _] <- get_resp_header(conn, "content-type"),
         true <- String.starts_with?(type, "text/html") do
      body = IO.iodata_to_binary(conn.resp_body)
      %{conn | resp_body: Regex.replace(~r/<body[^>]*>/, body, "\\0" <> @crumbs, global: false)}
    else
      _other -> conn
    end
  end

  def add_crumbs(conn), do: conn
end
