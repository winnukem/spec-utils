package C::EnumSet;
use namespace::autoclean;
use Moose;

use C::Enum;
use Local::C::Transformation qw(:RE);

use re '/aa';

extends 'C::Set';

has '+set' => (
   isa => 'ArrayRef[C::Enum]',
);


#FIXME: check for duplicates?
sub parse_enum
{
   my $self = shift;
   my @enums;

   my $name = qr!(?<ename>[a-zA-Z_]\w*)!;
   
   while ( $_[0] =~ m/^${h}*+
         enum
         ${s}++
            (?:$name)?
         ${s}*+
         (?>
            (?<ebody>
            \{
               (?:
                  (?>[^\{\}]+)
                  |
                  (?&ebody)
               )*
            \}
            )
         )${s}*+;
      /gmpx) {
      push @enums, C::Enum->new(name => $+{ename}, code => ${^MATCH})
   }

   return $self->new(set => \@enums);
}


__PACKAGE__->meta->make_immutable;

1;