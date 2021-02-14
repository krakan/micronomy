use Cro::HTTP::Log::File;
use Cro::HTTP::Server;
use Routes;

my $host = %*ENV<MICRONOMY_HOST> || 'localhost';
my $port = %*ENV<MICRONOMY_PORT> || 80;
my $prot = 'http';
my %tls = ();
if %*ENV<MICRONOMY_TLS_KEY> {
    %tls = %(
        private-key-file => %*ENV<MICRONOMY_TLS_KEY>,
        certificate-file => %*ENV<MICRONOMY_TLS_CERT>
    );
    $host = %*ENV<MICRONOMY_HOST> || '0.0.0.0';
    $port = %*ENV<MICRONOMY_PORT> ||  443;
    $prot = 'https';
}

my Cro::Service $http = Cro::HTTP::Server.new(
    http => <1.1>,
    host => $host,
    port => $port,
    tls => %tls,
    application => routes(),
    after => [
        Cro::HTTP::Log::File.new(logs => $*OUT, errors => $*ERR)
    ]
);
$http.start;
say "Listening at $prot://$host:$port";
react {
    whenever signal(SIGINT) {
        say "Shutting down...";
        $http.stop;
        done;
    }
}
