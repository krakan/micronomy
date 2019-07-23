use Cro::HTTP::Router;
use Cro::HTTP::Client;
use Cro::HTTP::Cookie;
use URI::Encode;

class Micronomy {

    my $server = "https://b3iaccess.deltekenterprise.com";

    method get-login(:$username, :$reason) {
        my $message = $reason ?? "<div class='error'>{$reason}</div>\n" !! "";

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
        if $username and $password {
            my $uri = "$server/containers/v1/b3/api_currentemployee/data;any";
            my $resp = await Cro::HTTP::Client.get(
                $uri,
                auth => {
                    username => $username,
                    password => $password
                },
                headers => {
                    Maconomy-Authentication => 'X-Reconnect',
                },
            );

            my @headers = $resp.headers;
            for @headers -> $header {
                next if $header.name ne 'Maconomy-Reconnect';
                $token = $header.value;
                last;
            }

            CATCH {
                when X::Cro::HTTP::Error {
                    my $error = (await .response.body)<errorMessage>;
                    $error = $error ?? '[' ~ .response.status ~ '] ' ~ $error !! .message();
                    $status = uri_encode_component($error);
                }
            }
        }
        if $token {
            set-cookie "sessionToken", $token;
            redirect "/", :see-other;
        } else {
            $status //= '';
            redirect "/login?username=$username&reason=$status", :see-other;
        }
    }

    method logout(:$username, :$token) {
        my $status;
        if $token {
            my $uri = "$server/containers/v1/b3/api_currentemployee/data;any";
            my $resp = await Cro::HTTP::Client.get(
                $uri,
                headers => {
                    Authorization => "X-Reconnect $token",
                    Maconomy-Authentication => "X-Log-Out",
                },
            );

            CATCH {
                when X::Cro::HTTP::Error {
                    # ignore errors
                }
            }
        }
        set-cookie "sessionToken", "";
        redirect "/login?username=$username&reason=Logged%20out", :see-other;
    }
}
