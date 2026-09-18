unit module Micronomy::OIDC;

use Cro::HTTP::Response;
use MIME::Base64;
use URI::Encode;

use Micronomy::Common;

# Maconomy speaks OIDC as just another authentication scheme: we send the browser to the
# identity provider, get an authorization code back and hand that code to Maconomy, which
# does the actual code-for-token exchange server side (it owns the client secret) and hands
# back the same Maconomy-Reconnect token a username/password login would have given us.
# See sso-oidc-investigation.md for how this was established.

my $authentication-type = 'application/vnd.deltek.maconomy.authentication+json';

# what Maconomy offers changes very rarely, and the login page asks on every render,
# so the answer is remembered - but a failed lookup is retried soon, so that a hiccup
# on the Maconomy side doesn't hide the SSO button for an hour
my $provider-ttl = 3600;
my $failure-ttl = 60;
my %provider-cache;
my $provider-checked;

#| the callback URL must be byte-identical in the authorization request and in the
#| code exchange, so both go through here
sub oidc-callback-url($url) is export {
    return $url.subst(/'?' .*/, '');
}

#| Micronomy's own callback URL - it has to match a redirect URI registered in Entra ID,
#| so MICRONOMY_CALLBACK_URL wins when set; otherwise it is derived from the request
#| (nginx passes the original Host through but terminates TLS, so https is assumed)
sub get-callback-url($request) is export {
    return %*ENV<MICRONOMY_CALLBACK_URL> if %*ENV<MICRONOMY_CALLBACK_URL>;
    my $host = $request.header('host') || 'localhost';
    my $scheme = $request.header('x-forwarded-proto') ||
        ($host.starts-with('localhost') || $host.starts-with('127.0.0.1') ?? 'http' !! 'https');
    return "$scheme://$host/login/oidc/callback";
}

#| the cached answer to "does Maconomy offer OIDC logins?" - pass :refresh to ask again
sub get-oidc-provider($auth-url, :$refresh) is export {
    my $ttl = %provider-cache ?? $provider-ttl !! $failure-ttl;
    if $refresh or not $provider-checked or now - $provider-checked > $ttl {
        %provider-cache = fetch-oidc-provider($auth-url) // {};
        $provider-checked = now;
    }
    return %provider-cache || Nil;
}

#| is SSO on offer right now? used to decide whether to show the login button at all
sub oidc-available($auth-url --> Bool) is export {
    return so get-oidc-provider($auth-url);
}

#| anonymous discovery call - returns the first configured OpenID provider,
#| or Nil if Maconomy isn't offering OIDC logins
sub fetch-oidc-provider($auth-url) {
    trace "getting oidc provider";
    my $response = call-url(
        $auth-url,
        timeout => 3,
        headers => {
            Accept => $authentication-type,
        },
    );

    unless $response ~~ Cro::HTTP::Response {
        trace "oidc discovery failed";
        return Nil;
    }

    my %authentication = (await $response.body)<authentication> // {};

    unless %authentication<schemes><x-oidc-code> {
        trace "oidc login unavailable - schemes: {(%authentication<schemes> // {}).keys.sort.join(', ')}";
        return Nil;
    }

    my %provider = %authentication<openIDProviders>[0] // {};
    unless %provider<links><authorization-url><template> {
        trace "oidc login unavailable - no authorization-url template";
        return Nil;
    }

    trace "found oidc provider {%provider<clientID> // '-'}";
    return %provider;

    CATCH {
        error $_;
        return Nil;
    }
}

#| build the identity provider's authorization URL from the template Maconomy gave us
sub get-authorization-url(%provider, $callback-url, :$prompt = '') is export {
    my $template = %provider<links><authorization-url><template> // return Nil;
    my $url = $template.subst(
        '{redirect-uri}',
        uri_encode_component(oidc-callback-url($callback-url)),
        :g,
    );
    # the web client forwards prompt (e.g. select_account) to let the user switch account
    $url ~= "&prompt={uri_encode_component($prompt)}" if $prompt;
    return $url;
}

#| hand the authorization code to Maconomy and get a reconnect token back - unlike
#| discovery this lets errors from call-url through, so the caller can tell the user why
#| the login failed instead of silently offering no SSO
sub exchange-oidc-code($auth-url, $callback-url, $code) is export {
    trace "exchanging oidc code";
    # <url>:code - the angle brackets are what the web client sends, and Maconomy needs
    # them to find the separator, since the URL contains colons of its own
    my $credentials = MIME::Base64.encode-str(
        "<{oidc-callback-url($callback-url)}>:$code",
        :oneline,
    );

    my $response = call-url(
        $auth-url,
        timeout => 3,
        headers => {
            Authorization => "X-OIDC-Code $credentials",
            Maconomy-Authentication => 'X-Reconnect',
        },
    );

    my $token = get-header($response, 'maconomy-reconnect');
    unless $token {
        trace "oidc code exchange returned no token";
        return Nil;
    }

    trace "logged in via oidc", $token;
    return $token;
}
