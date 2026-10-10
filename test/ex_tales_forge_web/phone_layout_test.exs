defmodule TalesForgeWeb.PhoneLayoutTest do
  @moduledoc """
  Phone layout and accessibility of the shared chrome: the play action form fits
  a 320px viewport, the admin nav wraps instead of scrolling sideways below `lg`,
  and the icon-only theme buttons have accessible names.
  """
  use TalesForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias TalesForgeWeb.{Layouts, PlayComponents}

  defp classes(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("class")
    |> List.first()
    |> String.split()
  end

  describe "play action form" do
    setup do
      html =
        render_component(&PlayComponents.narrative_panel/1,
          streams: %{entries: []},
          scene_loading: false,
          thinking: false,
          input_disabled: false
        )

      {:ok, html: html}
    end

    test "the input may shrink and the Act button may not", %{html: html} do
      # Without min-w-0 a text input keeps its ~255px intrinsic width and pushes
      # Act past the right edge of a 320px phone.
      input = classes(html, ~s(#action-form input[name="message"]))
      assert "flex-1" in input
      assert "min-w-0" in input

      assert "shrink-0" in classes(html, ~s(#action-form button[type="submit"]))
      assert "min-w-0" in classes(html, "#action-form")
    end

    test "the input has an accessible name", %{html: html} do
      assert html =~ ~s(aria-label="Your action")
    end
  end

  describe "admin nav" do
    setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

    test "phones get one Menu row that opens the groups; desktop shows them as a list", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, ~p"/admin/operate/costs")

      # One disclosure, no JavaScript: the summary names the current page.
      assert has_element?(view, "#admin-nav details#admin-nav-menu > summary", "Menu")
      assert has_element?(view, "#admin-nav-menu > summary", "Operate · Costs")
      # From lg up the summary is hidden and the content always shown.
      assert html =~ "#admin-nav-menu::details-content"
      refute "overflow-x-auto" in classes(html, "#admin-nav")

      # Phone-sized targets (44px) on the links, two per row below lg.
      assert "min-h-11" in classes(html, ~s(#admin-nav a[href="/admin/operate/costs"]))
      assert "grid-cols-2" in classes(html, "#admin-nav-operate ul")

      for label <- [
            "Admin home",
            "Costs",
            "Telemetry and AI calls",
            "Code docs",
            "← Player home",
            "Sign out"
          ] do
        assert has_element?(view, "#admin-nav a", label)
      end
    end
  end

  describe "theme toggle" do
    test "each icon-only button has an aria-label and a title" do
      html = render_component(&Layouts.theme_toggle/1, %{})

      for {theme, label} <- [
            {"system", "System theme"},
            {"light", "Light theme"},
            {"dark", "Dark theme"}
          ] do
        fragment = LazyHTML.from_fragment(html)
        button = LazyHTML.query(fragment, ~s(button[data-phx-theme="#{theme}"]))

        assert LazyHTML.attribute(button, "aria-label") == [label]
        assert LazyHTML.attribute(button, "title") == [label]
        assert LazyHTML.attribute(button, "type") == ["button"]
      end
    end

    test "the home page renders the labelled buttons", %{conn: conn} do
      {:ok, _view, html} = conn |> log_in_admin() |> live(~p"/")

      assert html =~ ~s(aria-label="System theme")
      assert html =~ ~s(aria-label="Light theme")
      assert html =~ ~s(aria-label="Dark theme")
    end
  end
end
