# Micronomy — SSO/OIDC Implementation TODO

Based on the findings in [`sso-oidc-investigation.md`](./sso-oidc-investigation.md).

## 1. Prerequisites (organizational — blocking, outside the codebase)

- [ ] Confirm with B3 IT / Deltek Maconomy admins whether the Azure AD app registration found on
      the live tenant (tenant `b238764b-05b9-48a7-a2bd-55a357dee4ae`, client
      `cb07fe18-05be-47c7-a945-27872d9ac3a2`) is intended for production SSO, or a forgotten
      test/dev configuration (its registered `redirectURI` is currently `http://localhost/`).
- [ ] Decide Micronomy's OIDC callback URL, e.g. `https://micronomy.init.se/login/oidc/callback`.
- [ ] Get that callback URL added to the Azure AD app registration's allowed redirect URIs in
      Entra ID (or get a new/dedicated app registration created and configured on the Maconomy
      side, if reusing the existing one isn't appropriate).
- [ ] Confirm how Maconomy maps an Azure AD identity (UPN? email? object id?) to a Maconomy
      employee number, and confirm every employee who needs Micronomy access already has that
      mapping set up on the Maconomy side.

## 2. Discovery &amp; token-exchange plumbing (`lib/Micronomy/OIDC.rakumod`)

Implemented in a new module `lib/Micronomy/OIDC.rakumod`. `get-header()` was moved from
`lib/Micronomy.rakumod` to `lib/Micronomy/Common.rakumod` (and exported) so both modules share it;
it now also returns an empty value instead of dying when `call-url` hands back `{}` after
timing out. `MIME::Base64` was added to `META6.json` and the `Dockerfile`'s `zef install` line.

- [x] Add a `get-oidc-provider()` sub: anonymous `GET maconomy-api/auth/b3` with
      `Accept: application/vnd.deltek.maconomy.authentication+json`, no auth headers.
- [x] Parse the response for `authentication.schemes<x-oidc-code>` (bail out / fall back to
      password login if absent) and `authentication.openIDProviders[0].links<authorization-url><template>`.
- [x] Add a helper to build the final authorization URL: substitute `{redirect-uri}` in the
      template with Micronomy's own callback URL, forward a `prompt` query param through if
      present (mirrors the real web client's "switch account" support).
      (`get-authorization-url(%provider, $callback-url, :$prompt)`, plus `oidc-callback-url()`
      which strips the query string so the redirect URI is byte-identical in both steps.)
- [x] Add a helper to build the `X-OIDC-Code` exchange request:
      `Authorization: X-OIDC-Code <base64("<<callback-url-without-query>>:<code>")>` — note the
      angle brackets around the URL, without which Maconomy answers 401 (see the investigation
      document; this was found the hard way on the first live attempt), `GET` to the
      same `maconomy-api/auth/b3` endpoint, read `Maconomy-Reconnect` from the response headers
      via the existing `get-header()` helper. (`exchange-oidc-code($auth-url, $callback-url, $code)`.)

Verified: `get-oidc-provider()` was run against the live tenant (anonymous GET only) and returns
the Azure AD provider from the investigation; the URL/base64 helpers were checked against the
template it returns. `exchange-oidc-code()` is still unverified end-to-end — it needs a real
authorization code, i.e. the section 1 prerequisites and a live test (section 6).

## 3. Routes &amp; login flow (`Routes.rakumod`, `lib/Micronomy.rakumod`)

The callback URL is computed per request by `get-callback-url($request)` in `Micronomy::OIDC`:
`MICRONOMY_CALLBACK_URL` wins when set (use it in production, since the URL has to match the
redirect URI registered in Entra ID byte for byte), otherwise it is derived from the request's
`Host` header, using `X-Forwarded-Proto` when present and assuming `https` otherwise — nginx
passes `Host` through but terminates TLS and sets no `X-Forwarded-Proto`. No nginx change is
needed: its `location ~ ^/(...|login|...)` regex already covers `/login/oidc` and
`/login/oidc/callback`.

- [x] `GET 'login/oidc'` — call the discovery helper, build the authorization URL, `redirect` the
      browser there. (Route → `Micronomy.start-oidc-login`; `?prompt=` is forwarded.)
- [x] `GET 'login/oidc/callback'` — read `?code=` (and handle a `?error=`/`?error_description=`
      from the IdP gracefully), call the exchange helper, get back the reconnect token.
- [x] Add `Micronomy.login-oidc(code, callback-url)` mirroring `Micronomy.login()`: on success,
      `set-cookie("sessionToken", token, ...)` exactly as today and redirect to `/`; on failure,
      fall through to `Micronomy.get-login(reason => ...)` with a Swedish error message,
      consistent with the existing error strings.
- [x] Reuse `fix-token`, `trace`/`error` (hashed-token logging), and the existing retry pattern in
      `call-url` for the two new outbound HTTP calls — no new logging or retry mechanism needed.
      (`fix-token` is applied where it always was, when the cookie is read back; like
      `Micronomy.login()`, the fresh token from `Maconomy-Reconnect` goes into the cookie verbatim.)

Verified with a stubbed Maconomy (routes exercised end to end, no live calls): `/login/oidc`
redirects with the correct `redirect_uri` and optional `prompt`; a good code sets the same
`sessionToken` cookie and redirects to `/`; a rejected code, an IdP `?error=`, and a callback with
neither show their login-page errors; discovery being down or not offering `x-oidc-code` falls back
to "SSO är inte tillgängligt just nu"; the password login page is unchanged.

Not implemented (not in this plan, worth a decision):

- No `state` parameter is sent with the authorization request, so nothing ties a callback to the
  browser that started the flow. Maconomy's own template doesn't include one either, but adding
  `&state=<random>` plus a short-lived cookie would protect against login-CSRF.
- ~~The `sessionToken` cookie is `SameSite=Strict`~~ — **resolved 2026-09-18, and the cause was
  not SameSite.** The first two live logins succeeded at Maconomy but bounced back to the login
  page, because the cookie was set without a `Path`: a browser then scopes it to the directory of
  the URL that set it, here `/login/oidc`, so it never reached `/`. The password login had always
  got away with this, being set from `POST /login`, whose directory is `/`. All four `sessionToken`
  writes now pass `path => '/'` explicitly.

  The OIDC cookie is also `SameSite=Lax` where the password login's stays `Strict`: the browser
  reaches the callback by a cross-site navigation from the identity provider, and a Strict cookie is
  withheld from the redirect that follows. Lax still keeps the cookie off every cross-site POST, and
  every state change in Micronomy is a POST. Making the password login Lax too would be a
  defensible simplification — one policy instead of two, and external links into Micronomy would
  stop landing on the login page while logged in — but that is a deliberate decision about the
  existing login, not a side effect of adding SSO.

## 4. Frontend

- [x] Add an SSO login button/link to `resources/templates/login.html.tmpl` pointing at
      `/login/oidc` (e.g. "Logga in med Microsoft"). It is a second `GET` form submitting to
      `/login/oidc`, so it reuses the existing `.login-button` styling (and its per-theme colours)
      as is; the only new CSS is `.sso-form` in `common.css`, which lines the button up under the
      password form. Wrapped in `<?.sso>`, so it only renders when SSO is actually on offer.
- [x] Keep the existing username/password form and the `demo`/`demo` shortcut fully working
      alongside it (dual-mode during rollout).

## 5. Error handling &amp; edge cases

- [x] IdP returns `?error=`/`?error_description=` instead of `?code=` (user cancelled, access
      denied, etc.) → show a clear login-page error, don't crash.
- [x] Maconomy rejects the `X-OIDC-Code` exchange (expired/replayed code, mismatched
      redirect_uri) → show a clear login-page error and let the user retry from scratch.
- [x] Discovery call itself fails or `x-oidc-code` isn't in `schemes` (e.g. temporarily disabled
      on the Maconomy side) → hide/disable the SSO button rather than offering a broken flow.
      `get-login` asks `oidc-available()` and hides the button; someone who reaches `/login/oidc`
      anyway (bookmark, stale page) gets "SSO är inte tillgängligt just nu" instead of a broken
      redirect.

Discovery is cached in `Micronomy::OIDC` so rendering the login page doesn't cost a round trip to
Maconomy every time: a positive answer is kept for an hour, a negative one for a minute (so a
hiccup doesn't hide SSO for an hour), and `/login/oidc` re-checks before giving up.

Verified with the stubbed Maconomy: the login page offers both methods; six renders trigger exactly
one discovery call; `demo` and the password form still log in and set the same cookie; and the SSO
button disappears — with the password form untouched — both when Maconomy drops `x-oidc-code` and
when it is unreachable. The button's appearance in a real browser hasn't been eyeballed yet.

## 6. Testing &amp; rollout

- [ ] End-to-end test against a non-production/sandbox Maconomy + Azure AD setup if one exists;
      otherwise coordinate a controlled first test in production with B3 IT.
- [ ] Verify everything downstream of login (week fetch, concurrency control, caching) behaves
      identically for an OIDC-derived session — it should, since it's the same reconnect token
      shape, but confirm empirically.
- [ ] Decide rollout strategy: keep dual-mode long-term, or eventually make SSO the
      `preferred` method and demote/remove the password form.
- [ ] Update `README.md` to document the new login option once shipped.
