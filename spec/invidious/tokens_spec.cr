require "../spec_helper"

Spectator.describe "CSRF_SCOPES" do
  # Every CSRF-protected form/ajax route registered in routing.cr, written as
  # the scope string validate_request derives from an incoming request:
  # "#{method}:#{path without leading slash}".
  #
  # A route missing from CSRF_SCOPES can never be handed a token that
  # validates, so it 400s on every request — and because that surfaces as a
  # plain 400 rather than a crash, it reads like a client bug rather than a
  # missing scope. That's how the don't-recommend buttons shipped broken.
  PROTECTED_ROUTES = [
    "POST:authorize_token",
    "POST:not_recommend_ajax",
    "POST:playlist_ajax",
    "POST:subscription_ajax",
    "POST:token_ajax",
    "POST:watch_ajax",
  ]

  it "grants every CSRF-protected ajax route" do
    scopes = CSRF_SCOPES.to_a

    missing = PROTECTED_ROUTES.reject { |route| scopes_include_scope(scopes, route) }

    expect(missing).to eq([] of String)
  end

  it "doesn't blanket-grant an unrelated route" do
    expect(scopes_include_scope(CSRF_SCOPES.to_a, "POST:some_other_ajax")).to be_false
  end
end
