defmodule TalesForge.AppRoleTest do
  use ExUnit.Case, async: true

  alias TalesForge.AppRole

  doctest AppRole

  test "surveys live on production, playtest runs on playtest, both locally" do
    assert AppRole.here?(:surveys, :production)
    refute AppRole.here?(:surveys, :playtest)
    assert AppRole.here?(:playtest_runs, :playtest)
    refute AppRole.here?(:playtest_runs, :production)
    assert AppRole.here?(:surveys, :local)
    assert AppRole.here?(:playtest_runs, :local)
  end

  test "redirect_url sends a path to the app that owns it, keeping the query" do
    assert AppRole.redirect_url("/admin/surveys/x", "tab=2", :playtest) ==
             "https://tales-forge.fly.dev/admin/surveys/x?tab=2"

    assert AppRole.redirect_url("/admin/playtest/abc", nil, :production) ==
             "https://tales-forge-playtest.fly.dev/admin/playtest/abc"

    assert AppRole.redirect_url("/admin/survey", "", :production) == nil
    assert AppRole.redirect_url("/admin/playtest", nil, :playtest) == nil
    assert AppRole.redirect_url("/admin/sessions", nil, :playtest) == nil
    assert AppRole.redirect_url("/admin/surveyx", nil, :playtest) == nil
    assert AppRole.redirect_url("/admin/surveys", nil, :local) == nil
  end

  test "link is the path here and the full URL on the other app" do
    assert AppRole.link(:surveys, "/admin/survey", :production) == "/admin/survey"

    assert AppRole.link(:surveys, "/admin/survey", :playtest) ==
             "https://tales-forge.fly.dev/admin/survey"

    assert AppRole.link(:playtest_runs, "/admin/playtest", :production) ==
             "https://tales-forge-playtest.fly.dev/admin/playtest"
  end
end
