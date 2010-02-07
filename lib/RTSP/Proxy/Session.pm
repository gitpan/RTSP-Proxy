package RTSP::Proxy::Session;

use Moose;

use RTSP::Client '0.03';

has rtsp_client => (
    is => 'rw',
    isa => 'RTSP::Client',
    lazy => 1,
    builder => 'build_rtsp_client',
);

has client_opts => (
    is => 'rw',
    isa => 'HashRef',
    default => sub { {} },
    lazy => 1,
);

has media_uri => (
    is => 'rw',
    isa => 'Str',
    required => 1,
);


sub build_rtsp_client {
    my $self = shift;
    my $rc = RTSP::Client->new_from_uri(
        uri => $self->media_uri,
        %{$self->client_opts},
    );
    return $rc;
}

__PACKAGE__->meta->make_immutable;
