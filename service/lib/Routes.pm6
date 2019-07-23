use Cro::HTTP::Router;
use Micronomy;

sub routes() is export {
    route {
        get -> :$sessionToken is cookie {
            if $sessionToken {
                content 'text/html', "<h1> micronomy $sessionToken </h1>";
            } else {
                redirect "/login?reason=Please%20log%20in", :see-other;
            }
        }
        get -> 'login', :$username = '', :$reason = '' {
            Micronomy.get-login(username => $username, reason => $reason)
        }
        post -> 'login' {
            request-body -> (:$username = '', :$password = '') {
                Micronomy.login(username => $username, password => $password)
            }
        }
        post -> 'logout', :$sessionToken is cookie = '' {
            request-body -> (:$username = '') {
                Micronomy.logout(username => $username, token => $sessionToken)
            }
        }
    }
}
