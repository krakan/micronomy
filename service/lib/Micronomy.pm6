use Cro::HTTP::Router;
use Cro::HTTP::Client;
use Cro::HTTP::Cookie;
use HTTP::UserAgent;
use URI::Encode;

class Micronomy {

    my $server = "https://b3iaccess.deltekenterprise.com";
    my $ua = HTTP::UserAgent.new;

    method get-login(:$username, :$reason) {
        my $message = $reason ?? "<div class='reason'>" ~ $reason ~ "</div>\n" !! "";

        content 'text/html', $message ~ qq:to/HTML/;
          <form method="POST" action="/login">
            <div>
              Username: <input type="text" name="username" value="$username" />
            </div>
            <div>
              Password: <input type="password" name="password" />
            </div>
            <input type="submit" value="Log In" />
          </form>
          HTML
    }

    method login(:$username, :$password) {
        my ($token, $status);
        if $username && $password {
            $ua.auth($username, $password);
            my $login = $ua.get(
                "$server/containers/v1/b3/api_currentemployee/data;any",
                Maconomy-Authentication => 'X-Reconnect',
            );
            $status = $login.code;

            if $status == 200 {
                my @headers = $login.header.fields;
                for @headers ->  $header {
                    next if $header.name ne 'Maconomy-Reconnect';
                    $token = $header.values[0];
                    last;
                }
            }
        }

        if $token {
            set-cookie "sessionToken", $token;
            redirect "/", :see-other;
        } else {
            my $message = $status ?? uri_encode_component("[$status] Login failed!") !! "";
            redirect "/login?username=$username&reason=" ~ $message, :see-other;
        }
    }
}
