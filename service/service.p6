use Cro::HTTP::Log::File;
use Cro::HTTP::Server;
use Routes;
use Micronomy;

my $micronomy = Micronomy.new;

my Cro::Service $http = Cro::HTTP::Server.new(
    http => <1.1 2>,
    host => %*ENV<MICRONOMY_HOST> ||
        die("Missing MICRONOMY_HOST in environment"),
    port => %*ENV<MICRONOMY_PORT> ||
        die("Missing MICRONOMY_PORT in environment"),
    tls => %(
        private-key-file => %*ENV<MICRONOMY_TLS_KEY> ||
            %?RESOURCES<fake-tls/server-key.pem> || "resources/fake-tls/server-key.pem",
        certificate-file => %*ENV<MICRONOMY_TLS_CERT> ||
            %?RESOURCES<fake-tls/server-crt.pem> || "resources/fake-tls/server-crt.pem",
    ),
    application => routes($micronomy),
    after => [
        Cro::HTTP::Log::File.new(logs => $*OUT, errors => $*ERR)
    ]
);
$http.start;
say "Listening at https://%*ENV<MICRONOMY_HOST>:%*ENV<MICRONOMY_PORT>";
react {
    whenever signal(SIGINT) {
        say "Shutting down...";
        $http.stop;
        done;
    }
}
