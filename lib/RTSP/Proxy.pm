package RTSP::Proxy;

use Moose;
extends 'Net::Server::PreFork';

use RTSP::Proxy::Session;
use Carp qw/croak/;

our $VERSION = '0.02';

=head1 NAME

RTSP::Proxy - Simple RTSP proxy server

=head1 SYNOPSIS

  use RTSP::Proxy;
  my $proxy = RTSP::Proxy->new({
      rtsp_client => {
          address            => '10.0.1.105',
          media_path         => '/mpeg4/media.amp',
          client_port_range  => '6970-6971',
          transport_protocol => 'RTP/AVP;unicast',
      },
      port   => 554,
      listen => 5,
  });
  
  $proxy->run;

=head1 DESCRIPTION

This module is a simple RTSP proxy based on L<Net::Server> and L<RTSP::Client>.

When a client connects and sends commands to the server, it will pass them through the RTSP client and return the results back.

This has only been tested with VLC and Axis IP cameras, it may not work with your setup. Patches and feedback welcome.

Note: you will need to be root to bind to port 554, you may drop privs if you wish. See the configuration options in L<Net::Server> for more details.

=head2 EXPORT

None by default.

=head2 METHODS

=over 4

=cut

has session => (
    is => 'rw',
    isa => 'RTSP::Proxy::Session',
);

sub process_request {
    my $self = shift;
    
    my $method;
    my $uri;
    my $proto;
    my $headers = {};
    
    READ: while (my $line = <STDIN>) {
        $self->log(4, "got line: $line");
        
        unless ($method) {
            # first line should be method
            ($method, $uri, $proto) = $line =~ m!(\w+)\s+(\S+)(?:\s+(\S+))?\r\n!ism;
            
            $self->log(4, "method: $method, uri: $uri, protocol: $proto");
            
            unless ($method && $uri && $proto =~ m!RTSP/1.\d!i) {
                $self->log(1, "Invalid request: $line");
                return $self->return_status(403, 'Bad request');
            }
            next READ;
        } else {
            goto DONE if $line eq "\r\n";
            
            # header
            my ($header_name, $header_value) = $line =~ /^([-A-Za-z0-9]+)\s*:\s*(.*)\r\n/;
            unless ($header_name) {
                $self->log(1, "Invalid header: $line");
                next;
            }
            
            $headers->{$header_name} = $header_value;
            next READ;
        }
        
        DONE:
        last unless $method && $proto;
    
        $method = uc $method;
    
        # get/create session
        my $session;
        if ($self->{server}{session}) {
            $session = $self->{server}{session};
        } else {
            # replace our port/address with the client's requested port/address
            my $client_settings = $self->{server}{rtsp_client} or die "Could not find client configuration";
        
            # no session id was sent, create one
            $session = RTSP::Proxy::Session->new(client_opts => $client_settings, media_uri => $uri);
            $self->{server}{session} = $session;
        }
    
        if ($method eq 'PLAY') {
            $session->rtsp_client->reset;
        }
        
        $self->proxy_request($method, $uri, $session, $headers);
    
        # so we can reuse the client for more requests
        if ($method eq 'SETUP' || $method eq 'DESCRIBE' || $method eq 'TEARDOWN') {
            $self->log(4, "resetting rtsp client");
            $session->rtsp_client->reset;
        }
    
        $method = '';
        $uri = '';
        $proto = '';
        $headers = {};
    }
}

sub proxy_request {
    my ($self, $method, $uri, $session, $headers) = @_;
    
    $self->log(4, "proxying $method / $uri to " . $session->rtsp_client->address);
    
    my $client = $session->rtsp_client;
    
    unless ($client->connected) {
        # open a connection
        unless ($client->open) {
            $self->log(0, "Failed to connect to camera: $!");
            return $self->return_status(404, "Resource not found");
        }
    }
    
    # pass through some headers
    foreach my $header_name (qw/
        Accept Bandwidth Accept-Language ClientChallenge PlayerStarttime RegionData
        GUID ClientID Transport Session x-retransmit x-dynamic-rate x-transport-options
        /) {
            
        my $header_value = $headers->{$header_name};
        $client->add_req_header($header_name, $header_value) if defined $header_value;
    }
    
    # do request
    $self->log(3, "proxying $method");
    my $ok;
    my $body;
    if ($method eq 'SETUP') {
        $ok = $client->setup;
    } elsif ($method eq 'DESCRIBE') {
        # proxy body response
        $body = $client->describe;
    } elsif ($method eq 'OPTIONS') {
        $ok = $client->options;
    } elsif ($method eq 'TEARDOWN') {
        $ok = $client->teardown;
    } else {
        $ok = $client->request($method);
    }
    
    my $status_message = $client->status_message;
    my $status_code = $client->status;
    
    $self->log(4, "$status_code $status_message - got headers: " . $client->_rtsp->headers_string . "\n");
    
    unless ($status_code) {
        $status_code = 405;
        $status_message = "Bad request";
    }
    
    my $res = '';

    # return status
    $res .= "RTSP/1.0 $status_code $status_message\r\n";
    
    # pass some headers back    
    foreach my $header_name (qw/
        Content-Type Content-Base Public Allow Transport Session
        /) {
        my $header_values = $client->get_header($header_name);
        next unless defined $header_values;
        foreach my $val (@$header_values) {
            $self->log(4, "header: $header_name, value: '$val'");
            $res .= "$header_name: $val\r\n";
        }
    }
    
    # respond with correct CSeq
    $res .= "CSeq: $headers->{CSeq}\r\n" if $headers->{CSeq};
    $res .= "Cseq: $headers->{Cseq}\r\n" if $headers->{Cseq};
    $res .= "cseq: $headers->{cseq}\r\n" if $headers->{cseq};
    
    if ($body) {
        $res .= "Content-Length: " . length($body) . "\r\n\r\n$body\r\n";
    }
    
    $self->write_line("$res");
}

sub write_line {
    my ($self, $line) = @_;
    print STDOUT "$line\r\n";
    $self->log(4, ">>$line");
}

sub return_status {
    my ($self, $code, $msg, $body) = @_;
    $body ||= '';
    print STDOUT "$code $msg\r\n$body\r\n";
    $self->log(3, "Returning status $code $msg");
}

sub default_values {
    return {
        proto        => 'tcp',
        listen       => 3,
        port         => 554,
    }
}

sub options {
    my $self     = shift;
    my $prop     = $self->{'server'};
    my $template = shift;

    ### setup options in the parent classes
    $self->SUPER::options($template);
    
    my $client = $prop->{rtsp_client}
        or croak "No rtsp_client definition specified";
    
    $template->{rtsp_client} = \ $prop->{rtsp_client};
}

__PACKAGE__->meta->make_immutable;

__END__




=head1 SEE ALSO

L<RTSP::Client>

=head1 AUTHOR

Mischa Spiegelmock, E<lt>revmischa@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Mischa Spiegelmock

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.0 or,
at your option, any later version of Perl 5 you may have available.

=head1 GUINEAS

SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSS 8DDDDDDDDDDDDDDDDDDDDDDDD horseBERD

=cut
