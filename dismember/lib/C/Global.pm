package C::Global;
use namespace::autoclean;
use Moose;

extends 'C::Entity';

__PACKAGE__->meta->make_immutable;

1;