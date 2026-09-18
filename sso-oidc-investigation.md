# Micronomy — SSO/OIDC Authentication: Findings &amp; Proposed Design

## Background

Micronomy currently authenticates by exchanging the user's B3 Maconomy username/password for a
Maconomy session token: `Micronomy.login()` sends `POST maconomy-api/auth/b3` with HTTP Basic
Auth, reads the `Maconomy-Reconnect` response header, and stores that token verbatim as the
`sessionToken` cookie. Every later request re-sends it as `Authorization: X-Reconnect <token>`.

This document records what was found by inspecting Deltek's official Maconomy Web Client API
reference and by probing B3's actual Maconomy tenant, and proposes how to add SSO via OIDC to
Micronomy on top of it.

## What the generic Deltek docs say

The Maconomy Web Client 2.6 Installation Guide's API reference
(`InstallationGuide/guide/05-apiReference.html`) documents an `IAuthenticationConfiguration`
schema with four pluggable login methods:

```
methods: {
  maconomy: { enabled: boolean },   // native username/password
  domain:   { enabled: boolean },   // Windows/domain auth
  sso:      { enabled: boolean },   // Kerberos-based SSO
  oauth:    { enabled: boolean },   // OAuth/OIDC
}
preferred: string
```

This confirms Maconomy has first-class SSO/OAuth support, but the reference page gives no
protocol-level detail (no endpoint paths, header names, or token formats). The live client version
running for B3 (11.1) is also much newer than this 2.6 doc, so behavior was verified directly
against the running system instead of relying on the doc.

## What was found on B3's live Maconomy tenant

### 1. The web client's own runtime config

`https://b3iaccess.deltekenterprise.com/config/config.js`:

```js
var mconfigWebclientAuthenticationMethods = 'None';
```

This only controls which login button(s) the web client's UI shows by default (`preferred`/
`alternative`) — it does **not** mean OIDC is unconfigured on the backend (see below).

### 2. The Maconomy auth endpoint already has Azure AD OIDC configured

An anonymous, unauthenticated `GET` (no credentials — the same request the real web client makes
on every page load) to:

```
GET https://b3iaccess.deltekenterprise.com/maconomy-api/auth/b3
Accept: application/vnd.deltek.maconomy.authentication+json
```

returns:

```json
{
  "authentication": {
    "useDomainCredentialsForBasicAuthentication": false,
    "schemes": {
      "basic": {"name": "basic"},
      "x-changepassword": {"name": "x-changepassword"},
      "bearer": {"name": "bearer"},
      "x-oidc-code": {"name": "x-oidc-code"},
      "x-reconnect": {"name": "x-reconnect"},
      "x-cookie": {"name": "x-cookie"},
      "x-resetpassword": {"name": "x-resetpassword"}
    },
    "openIDProviders": [
      {
        "authorizationEndpoint": "https://login.microsoftonline.com/b238764b-05b9-48a7-a2bd-55a357dee4ae/oauth2/authorize",
        "tokenEndpoint": "https://login.microsoftonline.com/b238764b-05b9-48a7-a2bd-55a357dee4ae/oauth2/token",
        "redirectURI": "http://localhost/",
        "clientID": "cb07fe18-05be-47c7-a945-27872d9ac3a2",
        "links": {
          "authorization-url": {
            "template": "https://login.microsoftonline.com/b238764b-05b9-48a7-a2bd-55a357dee4ae/oauth2/authorize?client_id=cb07fe18-05be-47c7-a945-27872d9ac3a2&scope=openid&response_type=code&redirect_uri={redirect-uri}"
          }
        }
      }
    ],
    "oauthConfigurations": []
  }
}
```

**B3's Maconomy tenant already has an Azure AD (Entra ID) OIDC provider registered**, tenant
`b238764b-05b9-48a7-a2bd-55a357dee4ae`, client ID `cb07fe18-05be-47c7-a945-27872d9ac3a2`.

⚠️ **Its registered `redirectURI` is `http://localhost/`** — almost certainly a leftover
dev/test value, not a production redirect target. **This must be confirmed with B3 IT / Deltek
before relying on it**: is this the Azure AD app registration intended for production SSO, or a
forgotten test configuration? Either way, Micronomy's real callback URL will need to be added to
that app registration's allowed redirect URIs in Entra ID before the flow will work end-to-end
(Azure AD rejects code exchanges to unregistered redirect URIs).

### 3. The actual login protocol (reconstructed from the web client's own Angular bundle)

Extracted from `main.*.js` served alongside the login page:

1. **Discover** — anonymous `GET maconomy-api/auth/b3` (above) → check `schemes` for
   `"x-oidc-code"`, read `openIDProviders[0].links["authorization-url"].template`.
2. **Redirect** — substitute `{redirect-uri}` in the template with your own callback URL
   (protocol+host+path, no query string), send the browser to the resulting Azure AD authorize
   URL. (A `?prompt=` query param on the current page, e.g. `select_account`, is forwarded
   through if present — used for "switch account".)
3. **Callback** — Azure AD redirects back to that same URL with `?code=<authorization code>`.
4. **Exchange** — call `GET maconomy-api/auth/b3` again, this time with:
   ```
   Authorization: X-OIDC-Code <base64("<<callback-url-without-query>>:<code>")>
   ```
   The callback URL is wrapped in **angle brackets** inside the base64 payload — Maconomy needs
   them to find the separator, since the URL contains colons of its own. Without them it answers
   `401 Credentials could not be extracted from authorization parameters.` The client's own
   builder, from `main.d39ca674eb41b909.js`, is:
   ```js
   setOidcAuthorization(fe, Ce) {
     const E1 = e.encode(`<${fe}>:${Ce}`);
     return this.setAuthorizationHeader(`X-OIDC-Code ${E1}`), this;
   }
   ```
   (verified 2026-09-18 against a real authorization code — see below)
   Maconomy's backend performs the actual code↔token exchange with Azure AD **server-side**
   (it owns the client secret), validates the ID token, maps the verified identity to a Maconomy
   employee, and returns `Maconomy-Reconnect: <token>` — **the exact same header the existing
   Basic-Auth login already reads.**

### Why this matters for Micronomy

`X-OIDC-Code` is just a fourth sibling to the `Basic` / `X-Reconnect` / `X-Log-Out` schemes
Micronomy already speaks. **No OIDC/JWT library is needed inside Micronomy** — it never talks to
Azure AD's token endpoint, never validates an ID token, never handles a client secret. It only
needs to perform a browser redirect and one more `GET` with a custom `Authorization` header,
reusing 100% of the existing token pipeline (`fix-token`, `get-header`, the `sessionToken` cookie,
the retry/logging helpers in `Micronomy::Common`).

## Proposed implementation (once the redirect-URI question is resolved with B3 IT)

- `GET /login/oidc` — call the discovery endpoint anonymously, build the authorization URL from
  the template using Micronomy's own callback path, redirect the browser.
- `GET /login/oidc/callback` — read `?code=`, call `maconomy-api/auth/b3` with
  `Authorization: X-OIDC-Code <base64(...)>` via the existing `call-url` helper, read back
  `Maconomy-Reconnect` exactly like `Micronomy.login` does today, set the same `sessionToken`
  cookie, redirect to `/`.
- Add an "SSO" button next to (or instead of) the password form in
  `resources/templates/login.html.tmpl`.
- Keep the `demo`/`demo` shortcut and the existing password path working in parallel during
  rollout.

## Open items before implementation

1. **Confirm with B3 IT / Deltek Maconomy admins**: is the Azure AD app registration found above
   (tenant `b238764b-...`, client `cb07fe18-...`) intended for production SSO, or a forgotten test
   config? Get Micronomy's real callback URL (e.g. `https://micronomy.init.se/login/oidc-callback`)
   added to its allowed redirect URIs in Entra ID.
2. **Verify identity-to-employee mapping**: confirm how Maconomy maps the Azure AD identity (UPN?
   email? object id?) to a Maconomy employee number, and whether every B3 employee who needs
   Micronomy access already has that mapping set up.
3. **One live test in a non-production context** (test tenant/sandbox, or coordinated with B3 IT)
   to confirm the exact response shape of a successful `X-OIDC-Code` exchange.

## Update 2026-09-18 — working end to end

Running Micronomy locally on `http://localhost/`, a real user reached Azure AD and came back to
`/login/oidc/callback?code=...` with a genuine authorization code, so the redirect leg works against
the app registration as it stands. Maconomy then rejected the exchange with
`401 Credentials could not be extracted from authorization parameters.` — the payload had been built
as `base64("url:code")`, without the angle brackets. Re-reading `setOidcAuthorization` in the current
bundle gave the exact format (above); the code now sends `base64("<url>:code")`.

With that fixed, a successful exchange returns exactly what the password login does: a
`Maconomy-Reconnect` header carrying a token of the same shape (`<base64>:<base64>`, 225 characters
in the observed case), which Micronomy stores in the `sessionToken` cookie and re-sends as
`X-Reconnect` like any other session. Two further problems were browser-side, not protocol:

- the cookie needs an explicit `path=/`, or it is scoped to `/login/oidc` and never reaches `/`;
- it needs `SameSite=Lax` rather than `Strict`, because the callback is reached by a cross-site
  navigation from Azure AD.

A full login — Azure AD sign-in, callback, exchange, timesheet — was completed against the live
tenant on 2026-09-18 with Micronomy running locally on `http://localhost/`, which also means the
existing app registration accepts that callback URL as it stands.
