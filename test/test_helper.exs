# Unit tests never call a live LLM. A developer shell with XAI_API_KEY
# would otherwise make every turn POST to api.x.ai (and retry on failure).
System.put_env("LLM_PROVIDER", "mock")

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(TalesForge.Repo, :manual)
