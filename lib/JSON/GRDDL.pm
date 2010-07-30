package JSON::GRDDL;

use 5.008;
use common::sense;

use Carp;
use JSON;
use JSON::T;
use LWP::UserAgent;
use RDF::Trine;
use Scalar::Util qw[blessed];

our $VERSION = '0.001_00';

sub new
{
	my ($class) = @_;
	return bless { cache=>{}, ua=>undef, }, $class;
}

sub ua
{
	my $self = shift;
	if (@_)
	{
		my $rv = $self->{'ua'};
		$self->{'ua'} = shift;
		croak "Set UA to something that is not an LWP::UserAgent!"
			unless blessed $self->{'ua'} && $self->{'ua'}->isa('LWP::UserAgent');
		return $rv;
	}
	unless (blessed $self->{'ua'} && $self->{'ua'}->isa('LWP::UserAgent'))
	{
		$self->{'ua'} = LWP::UserAgent->new(agent=>sprintf('%s/%s ', __PACKAGE__, $VERSION));
	}
	return $self->{'ua'};
}

sub data
{
	my ($self, $document, $uri, %options) = @_;
	
	unless (ref $document)
	{
		$document = from_json("$document");
	}
	
	$options{'model'} ||= RDF::Trine::Model->temporary_model;
	
	my $T = $self->discover($document, $uri, %options);
	if ($T)
	{
		return $self->transform_by_uri($document, $uri, $T, %options);
	}
	elsif (ref $document eq 'HASH' and !$options{'nested'}
	  and  (not grep { $_ !~ /:/ } keys %$document))
	{
		# looks like it's bona-fide RDF/JSON.
		$options{'model'}->add_hashref($document);
		return $options{'model'};
	}
	elsif (ref $document eq 'HASH'
	  and  $document->{'$schema'}->{'$ref'} eq 'http://soapjr.org/schemas/RDF_JSON')
	{
		# claims it's bona-fide RDF/JSON.
		$options{'model'}->add_hashref($document);
		return $options{'model'};
	}
	
	# Not returned anything yet, so try recursing.
	{
		local $options{'nested'} = 1;
		
		if (ref $document eq 'HASH')
		{
			foreach my $item (values %$document)
			{
				if ('HASH' eq ref $item or 'ARRAY' eq ref $item)
				{
					$self->data($item, $uri, %options);
				}
			}
		}
		elsif (ref $document eq 'ARRAY')
		{
			foreach my $item (@$document)
			{
				if ('HASH' eq ref $item or 'ARRAY' eq ref $item)
				{
					$self->data($item, $uri, %options);
				}
			}
		}
	}
	
	return $options{'model'};
}

sub discover
{
	my ($self, $document, $uri, %options) = @_;
	my $T;
	
	unless (ref $document)
	{
		$document = from_json("$document");
	}

	return unless ref $document eq 'HASH';
	
	if (defined $document->{'$transformation'})
	{
		$T = $self->_resolve_relative_ref($document->{'$transformation'}, $uri);
	}
	elsif (defined $document->{'$schema'}->{'$schemaTransformation'})
	{
		$T = $self->_resolve_relative_ref($document->{'$schema'}->{'$schemaTransformation'}, $uri);
	}
	elsif (defined $document->{'$schema'}->{'$ref'})
	{
		my $s = $self->_resolve_relative_ref($document->{'$schema'}->{'$ref'}, $uri);
		my $r  = $self->_fetch($s,
			Accept => 'application/schema+json, application/x-schema+json, application/json');
		
		if (defined $r
		&&  $r->code == 200
		&&  $r->header('content-type') =~ m#^\s*(((application|text)/(x-)?json)|(application/(x-)?schema\+json))\b#)
		{
			my $schema = from_json($r->decoded_content);
			if (defined $schema->{'$schemaTransformation'})
			{
				$T = $self->_resolve_relative_ref($schema->{'$schemaTransformation'}, $s);
			}
		}
	}
	
	return $T;
}

sub transform_by_uri
{
	my ($self, $document, $uri, $transformation_uri, %options) = @_;
	
	my ($name) = ($transformation_uri =~ /\#(.+)$/);
	
	my $r = $self->_fetch($transformation_uri,
		Accept => 'application/ecmascript, application/javascript, text/ecmascript, text/javascript, application/x-ecmascript');
	if (defined $r
	&&  $r->code == 200
	&&  $r->header('content-type') =~ m#^\s*((application|text)/(x-)?(java|ecma)script)\b#)
	{
		return $self->transform_by_jsont($document, $uri, $r->decoded_content, $name, %options);
	}
	
	return;
}

sub transform_by_jsont
{
	my ($self, $document, $uri, $transformation, $name, %options) = @_;
	
	my $jsont = JSON::T->new($transformation, $name);
	my $out   = $jsont->transform_structure($document);
	
	$options{'model'} ||= RDF::Trine::Model->temporary_model;
	$options{'model'}->add_hashref($out);
	return $options{'model'};
}

sub _fetch
{
	my ($self, $document, %headers) = @_;
	$self->{'cache'}->{$document} ||= $self->ua->get($document, %headers);
	return $self->{'cache'}->{$document};
}

sub _resolve_relative_ref
{
	my ($self, $ref, $base) = @_;

	return $ref unless $base; # keep relative unless we have a base URI

	if ($ref =~ /^([a-z][a-z0-9\+\.\-]*)\:/i)
	{
		return $ref; # already an absolute reference
	}

	# create absolute URI
	my $abs = URI->new_abs($ref, $base)->canonical->as_string;

	while ($abs =~ m!^(http://.*)(\.\./|\.)+(\.\.|\.)?$!i)
		{ $abs = $1; } # fix edge case of 'http://example.com/../../../'

	return $abs;
}


1;