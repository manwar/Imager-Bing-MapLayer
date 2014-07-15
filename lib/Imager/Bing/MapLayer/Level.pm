package Imager::Bing::MapLayer::Level;

use v5.10.1;

use Moose;

use Carp qw/ confess /;
use Class::MOP::Method;
use Const::Fast;
use Cwd;
use Imager;
use List::Util qw/ min max /;
use Moose::Util::TypeConstraints;
use MooseX::StrictConstructor;
use POSIX::2008 qw/ round /;

use Imager::Bing::MapLayer::Utils qw/
    $MIN_ZOOM_LEVEL $MAX_ZOOM_LEVEL $TILE_WIDTH $TILE_HEIGHT
    width_at_level bounding_box pixel_to_tile_coords tile_coords_to_quad_key
    optimize_points get_ground_resolution tile_class_type
    /;

use Imager::Bing::MapLayer::Image;
use Imager::Bing::MapLayer::Tile;

use version 0.77; our $VERSION = version->declare('v0.1.3');

=head1 NAME

Imager::Bing::MapLayer::Level - zoom levels for Bing Maps

=head1 SYNOPSIS

    my $level = Imager::Bing::MapLayer::Level->new(
        level              => $level,   # zoom level
        base_dir           => $dir,     # base directory (default '.')
        overwrite          => 1,        # overwrite existing (default)
        autosave           => 1,        # save on exit (default)
        in_memory          => 0,        # keep tiles in memory (default false)
        combine            => 'darken', # tile combination method (default)
    );

    $level->polygon(
       points => $points,             # listref to [ lat, lon ] points
       fill   => Imager::Fill->new( ... ), #
    );

=head1 DESCRIPTION

=head1 ATTRIBUTES

=head2 C<level>

The zoom level.

=cut

has 'level' => (
    is  => 'ro',
    isa => subtype(
        as 'Int',
        where { ( $_ >= $MIN_ZOOM_LEVEL ) && ( $_ <= $MAX_ZOOM_LEVEL ) }
    ),
);

=head2 C<base_dir>

The base directory to save tile files in.

=cut

has 'base_dir' => (
    is  => 'ro',
    isa => subtype( as 'Str', where { -d $_ }, ),
    default => sub { return getcwd; },
);

=head2 C<centroid_latitude>

This is the default latitude for translating points to pixels.
Generally you don't need to worry about this.

=cut

has 'centroid_latitude' => (
    is      => 'ro',
    isa     => 'Num',
    default => sub { 0; },
);

=head2 C<centroid_longitude>

This is the default longitude for translating points to pixels.
Generally you don't need to worry about this.

=cut

has 'centroid_longitude' => (
    is      => 'ro',
    isa     => 'Num',
    default => sub { 0; },
);

=head2 C<tiles>

A hash reference of C<Imager::Bing::MapLayer::Tile> objects.

The keys are tile coordinates of the form C<$tile_x . $; . $tile_y>.

=cut

has 'tiles' => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { return {} },
);

=head2 C<timeouts>

=cut

# TODO - the last-modified value should be saved with each tile

has 'timeouts' => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { return {} },
);

=head2 C<last_cleanup_time>

=cut

has 'last_cleanup_time' => (
    is      => 'rw',
    isa     => 'Int',
    default => sub { return time; },
);

=head2 C<overwrite>

When true (default), existing tiles will be overwritten rather than
edited.

Be wary of editing existing tiles, since antialiased lines and opaque
fills will darken existing points rather than drawing over them.

=cut

has 'overwrite' => (
    is      => 'ro',
    isa     => 'Bool',
    default => sub { return 1; },
);

=head2 C<in_memory>

The timeout for how many seconds a tile is kept in memory.

When a tile is timed out, it is saved to disk after each L<Imager> drawing
operation, and reloaded if it is later needed.

=cut

has 'in_memory' => (
    is  => 'ro',
    isa => subtype( as 'Int', where { ( $_ >= 0 ) }, ),
    default => sub { return 0; },
);

=head2 C<autosave>

When true (default), tiles will be automatically saved.

Alternatively, you can use the L</save> method.

=cut

has 'autosave' => (
    is      => 'ro',
    isa     => 'Bool',
    default => sub { return 1; },
);

=head2 C<combine>

The tile combination method. It defaults to C<darken>.

=cut

has 'combine' => (
    is      => 'ro',
    isa     => 'Str',
    default => sub { return 'darken'; },
);

=head2 C<tile_class>

The base class used for tiles.

=cut

has 'tile_class' => (
    is      => 'ro',
    isa     => tile_class_type(),
    default => sub { 'Imager::Bing::MapLayer::Tile' },
);

=head1 METHODS

=head2 C<width>

The width of the layer.

=cut

sub width {
    my ($self) = @_;
    return width_at_level( $self->level );
}

=head2 C<height>

The height of the layer.

=cut

sub height {
    my ($self) = @_;
    return width_at_level( $self->level );
}

=head2 C<latlon_to_pixel>

  my ($x, $y) = $level->latlon_to_pixel($latitude, $longitude);

Translates a latitude and longitude coordinate into a pixel on the
zoom level.

=cut

sub latlon_to_pixel {
    my ( $self, @latlon ) = @_;
    return Imager::Bing::MapLayer::Utils::latlon_to_pixel( $self->level,
        @latlon );
}

=head2 C<_translate_points>

This is a utility method for translating C<points> parameters from
L<Imager> methods.

At lower zoom levels, these are "optimized" by removing duplicate
adjacent points.

=cut

sub _translate_points {
    my ( $self, $points ) = @_;
    return optimize_points(
        [ map { [ $self->latlon_to_pixel( @{$_} ) ] } @{$points} ] );
}

=head2 C<_translate_coords>

This is a utility method for translating C<box> parameters from
L<Imager> methods.

=cut

sub _translate_coords {
    my ( $self, $points ) = @_;
    no warnings 'once';
    return [ pairmap { ( $self->latlon_to_pixel( $a, $b ) ) } @{$points} ];
}

=head2 C<_translate_radius>

    my $pixels = $level->_translate_radius( $meters, $min_pixels);

This method translates the C<r> parameter for cirlces and arcs from
meters into pixels.

If the C<$min_pixels> parameter is given, then the radius will be no
smaller than the given number of pixels. (This is useful to ensure
that small circles show up on lower zoom levels.)

=cut

sub _translate_radius {
    my ( $self, $r, $min_r ) = @_;

    return max(
        round(
            $r / get_ground_resolution(
                $self->level, $self->centroid_latitude
            )
        ),
        $min_r // 0
    );
}

# This is a hash that says which utility method to use for translating
# point arguments for Imager methods.

const my %ARG_TO_METHOD => (
    points => '_translate_points',
    box    => '_translate_coords',    # TODO - this does not seem to work
    r      => '_translate_radius',
);

=head2 C<_translate_point_arguments>

This is an I<internal> utility method for translating coordinate
parameters from L<Imager> methods.

=cut

sub _translate_point_arguments {
    my ( $self, %args ) = @_;

    my %i_args;

    foreach my $arg ( keys %ARG_TO_METHOD ) {

        if ( my $method = $self->can( $ARG_TO_METHOD{$arg} ) ) {

            $i_args{$arg}
                = $self->$method( $args{$arg}, $args{"-min_${arg}"} )
                if ( exists $args{$arg} );

        }

    }

    # Ideally, we could translate x and y separately, using the
    # centroid_longitude and centroid_latitude as defaults for the
    # missing coordinate.  But this does not seem to work properly.
    # So we translate them together.

    # TODO - clean up this code.

    foreach my $suffix ( '', qw/ 1 2 min max / ) {

        my $x = $args{ 'x' . $suffix };
        my $y = $args{ 'y' . $suffix };

        # If either the x or y parameter is missing, then it won't be
        # translated.

        if ( ( defined $x ) && ( defined $y ) ) {

            if ( ( ref $x ) || ( ref $y ) ) {

                if ($suffix) {

                    confess
                        sprintf(
                        "x%s and y%s as coordinate lists are not supported");

                } else {

                    # If there are a pair of x,y coordinate lists,
                    # then we just reassemble them into a 'points'
                    # parameter and translate that.

                    # Note that this is based on how Imager treats
                    # these.

                    # TODO - rewrite this code

                    my @xs = ( ref $x ) ? @{$x} : ($x);
                    my @ys = ( ref $y ) ? @{$y} : ($y);

                    my $last_x = shift @xs;
                    my $last_y = shift @ys;

                    my @points = ( [ $last_y, $last_x ] );

                    while ( @xs || @ys ) {

                        my $this_x = ( shift @xs ) // $last_x;
                        my $this_y = ( shift @ys ) // $last_y;

                        push @points, [ $this_y, $this_x ];

                        ( $last_x, $last_y ) = ( $this_x, $this_y );

                    }

                    $i_args{points} = $self->_translate_points( \@points );

                }

            } else {

                my ( $pixel_x, $pixel_y ) = $self->latlon_to_pixel( $y, $x );
                $i_args{ 'x' . $suffix } = $pixel_x;
                $i_args{ 'y' . $suffix } = $pixel_y;

            }

        }

    }

    return %i_args;
}

=head2 C<_tile_coords_to_internal_key>

    my $key = $level->_tile_coords_to_internal_key($tile_x, $tile_y);

This is an I<internal method> for generating a key for the L</tiles>
and L</timeouts>.

We join the tile coordinates into a small key to use for this, instead
of generating a quad key (which requires more work, and is only needed
for creating a new tile).

=cut

sub _tile_coords_to_internal_key {
    my ( $self, $tile_x, $tile_y ) = @_;
    return join( $;, $tile_x, $tile_y );
}

=head2 C<_internal_key_to_tile_coords>


    my ($tile_x, $tile_y) = $level->_internal_key_to_tile_coords($key);

This is an I<internal> method for determining tile coordinates from a
key.  It is the inverse of L</_tile_coords_to_internal_key>.

=cut

sub _internal_key_to_tile_coords {
    my ( $self, $key ) = @_;
    return ( split $;, $key );
}

=head2 C<_load_tile>

    my $tile = $level->_load_tile($tile_x, $tile_y, $overwrite);

This is an I<internal> method that loads a tile for this level, if it
exists. Otherwise it creates a new tile.

=cut

sub _load_tile {
    my ( $self, $tile_x, $tile_y, $overwrite ) = @_;

    my $class = $self->tile_class;

    return $class->new(
        quad_key => tile_coords_to_quad_key( $self->level, $tile_x, $tile_y ),
        base_dir => $self->base_dir,
        overwrite => $overwrite,
        autosave  => $self->autosave,
    );

}

=head2 C<_cleanup_tiles>

    $level->_cleanup_tiles();

This is an I<internal> method that removes tiles from memory that have
not been drawn to within the L</in_memory> timeout.

=cut

sub _cleanup_tiles {
    my ($self) = @_;

    return unless $self->in_memory;

    my $time = time;

    if ( ( $self->last_cleanup_time + $self->in_memory ) < $time ) {

        my $tiles    = $self->tiles;
        my $timeouts = $self->timeouts;

        foreach my $key ( keys %{$tiles} ) {

            if ( $tiles->{$key} ) {

                if ( $timeouts->{$key} < $time ) {

                    # For some reason, ignoring save when
                    # $self->autosave is true does not seem to
                    # consistently save the tile. So we always save
                    # it.

                    $tiles->{$key}->save;

                    $tiles->{$key} = undef;

                    delete $timeouts->{$key};

                }

            }

        }

        $self->last_cleanup_time($time);
    }
}

=head2 C<_make_imager_wrapper_method>

This is an I<internal> function generates wrapper methods for a tile's
L<Imager::Draw> methods.

Basically, it calculates the bounding box for whatever is to be drawn, and creates a
L<Imager::Bing::MapLayer::Image> "pseudo-tile" to draw on.

It then composes pieces from the pseudo tile onto the actual tile
(using the L</combine> method>).

=cut

sub _make_imager_wrapper_method {
    my ( $class, $opts ) = @_;

    $opts->{args} //= [];
    $opts->{name} //= "undef";    # to catch missing method names

    $class->meta->add_method(

        $opts->{name} => sub {

            my ( $self, %args ) = @_;

            return
                if (
                ( $args{'-min_level'} // $MIN_ZOOM_LEVEL ) > $self->level );
            return
                if (
                ( $args{'-max_level'} // $MAX_ZOOM_LEVEL ) < $self->level );

            my %imager_args = $self->_translate_point_arguments(%args);

            foreach my $arg ( @{ $opts->{args} } ) {
                $imager_args{$arg} = $args{$arg} if ( exists $args{$arg} );
            }

            my ( $left, $top, $right, $bottom ) = bounding_box(%imager_args);

            # We create a temporary image and draw on it. We then
            # compose the appropriate pieces of that image on each
            # tile.  This is faster than drawing the image on every
            # tile, for complex polylines and polygons like geographic
            # boundaries.

            # TODO - for very large polygons, this will require images
            # that are too large for higher zoom levels. We need to
            # modify this to render images on multiple pseudo-tiles.

            # TODO - get* methods should be handled differently.

            # Note: Try::Tiny does not catch malloc errors

            my $image = Imager::Bing::MapLayer::Image->new(
                pixel_origin => [ $left, $top ],
                width        => 1 + $right - $left,
                height       => 1 + $bottom - $top,
            );

            unless ($image) {

                confess
                    sprintf(
                    "unable to create image for (%d , %d) (%d , %d) at level %d: %s",
                    $left, $top, $right, $bottom, $self->level, $_ );

            }

            if ( my $method = $image->can( $opts->{name} ) ) {

                my $result = $image->$method(%imager_args);

                # Now get the tile boundaries

                my ( $tile_left, $tile_top )
                    = pixel_to_tile_coords( $left, $top );
                my ( $tile_right, $tile_bottom )
                    = pixel_to_tile_coords( $right, $bottom );

                my $tiles    = $self->tiles;
                my $timeouts = $self->timeouts;

                for (
                    my $tile_y = $tile_top;
                    $tile_y <= $tile_bottom;
                    $tile_y++
                    )
                {

                    for (
                        my $tile_x = $tile_left;
                        $tile_x <= $tile_right;
                        $tile_x++
                        )
                    {

                        my $key
                            = $self->_tile_coords_to_internal_key( $tile_x,
                            $tile_y );

                        unless ( defined $tiles->{$key} ) {

                            my $overwrite
                                = ( exists $tiles->{$key}
                                    && $self->in_memory )
                                ? 0
                                : $self->overwrite;

                            $tiles->{$key}
                                = $self->_load_tile( $tile_x, $tile_y,
                                $overwrite );

                            $timeouts->{$key} = time() + $self->in_memory;
                        }

                        if ( my $tile = $tiles->{$key} ) {

                            my $crop_left = max( $left, $tile->left );
                            my $crop_top  = max( $top,  $tile->top );

                            my $crop = $image->crop(
                                left  => $crop_left,
                                top   => $crop_top,
                                width => 1 + min(
                                    $right - $crop_left,
                                    $tile->right - $crop_left
                                ),
                                height => 1 + min(
                                    $bottom - $crop_top,
                                    $tile->bottom - $crop_top
                                ),
                            );

                            $tile->compose(
                                src     => $crop,
                                left    => $crop_left,
                                top     => $crop_top,
                                width   => $crop->getwidth,
                                height  => $crop->getheight,
                                combine => $self->combine,
                            );

                            $crop = undef;    # force garbage collection

                            if ( $self->in_memory ) {

                                $timeouts->{$key} = time() + $self->in_memory;

                                $self->_cleanup_tiles();

                            } else {

                                # See comments about regarding
                                # autosave consistency.

                                $tile->save;

                                $tiles->{$key} = undef;

                            }

                        }

                    }
                }

                $image = undef;    # force garbage collection

            } else {

                confess sprintf( "invalid method name: %s", $opts->{name} );

            }

        },
    );

}

__PACKAGE__->_make_imager_wrapper_method( { name => 'radial_circle', } );

__PACKAGE__->_make_imager_wrapper_method( { name => 'getpixel', } );

__PACKAGE__->_make_imager_wrapper_method(
    {   name => 'setpixel',
        args => [qw/ color /],
    }
);

__PACKAGE__->_make_imager_wrapper_method(
    {   name => 'line',
        args => [qw/ color endp aa antialias /],
    }
);

__PACKAGE__->_make_imager_wrapper_method(
    {   name => 'box',
        args => [qw/ color filled fill /],
    }
);

__PACKAGE__->_make_imager_wrapper_method(
    {   name => 'polyline',
        args => [qw/ color aa antialias /],
    }
);

__PACKAGE__->_make_imager_wrapper_method(
    {   name => 'polygon',
        args => [qw/ color fill /],
    }
);

__PACKAGE__->_make_imager_wrapper_method(
    {   name => 'arc',
        args => [qw/ d1 d2 color fill aa filled /],
    }
);

__PACKAGE__->_make_imager_wrapper_method(
    {   name => 'circle',
        args => [qw/ color fill aa filled /],
    }
);

__PACKAGE__->_make_imager_wrapper_method(
    {   name => 'flood_fill',
        args => [qw/ color border fill /],
    }
);

__PACKAGE__->_make_imager_wrapper_method(
    {   name => 'string',
        args => [
            qw/ string font aa align channel color size sizew utf8 vlayout text /
        ],
    }
);

__PACKAGE__->_make_imager_wrapper_method(
    {   name => 'align_string',
        args => [
            qw/ string font aa valign halign channel color size sizew utf8 vlayout text /
        ],
    }
);

# TODO/FIXME - generic method with callbacks to apply a function to a
# all tiles on a level?

=head2 C<filter>

Apply a L<Imager::Filter> to every tile in the level.

Only tiles that have been drawn to will have filters applied to them.

=cut

sub filter {
    my ( $self, %args ) = @_;

    foreach my $key ( keys %{ $self->tiles } ) {

        my $tile = $self->tiles->{$key};

        unless ($tile) {    # assume $self->in_memory

            my ( $tile_x, $tile_y )
                = $self->_internal_key_to_tile_coords($key);

            # We assume that a tile should not be overwritten

            my $overwrite = $self->in_memory ? 0 : $self->overwrite;

            $tile = $self->_load_tile( $tile_x, $tile_y, $overwrite );

        }

        if ($tile) {

            $tile->image->filter(%args)
                or confess $tile->image->errstr;

            # See comments abouve regarding autosave consistency.

            $tile->save;

        }
    }

}

=head2 C<colourise>

    $level->colourise();

Runs the C<colourise> method on tiles.

This method is intended to be run for after rendering on the level is
completed, i.e. for post-processing of heatmap tiles.

=cut

sub colourise {
    my ( $self, %args ) = @_;

    foreach my $key ( keys %{ $self->tiles } ) {

        my $tile = $self->tiles->{$key};

        unless ($tile) {    # assume $self->in_memory

            my ( $tile_x, $tile_y )
                = $self->_internal_key_to_tile_coords($key);

            # We assume that a tile should not be overwritten

            my $overwrite = $self->in_memory ? 0 : $self->overwrite;

            $tile = $self->_load_tile( $tile_x, $tile_y, $overwrite );

        }

        if ($tile) {

            $tile->colourise(%args);

            # See comments about regarding autosave consistency.

            $tile->save;

        }
    }

}

=head2 C<save>

    $level->save();

Saves the titles.

If L<in_memory> is non-zero, tiles that have timed out are removed
from memory.

=cut

sub save {
    my ( $self, @args ) = @_;

    $self->_cleanup_tiles();

    foreach my $tile ( values %{ $self->tiles } ) {
        $tile->save(@args) if ($tile);
    }
}

use namespace::autoclean;

1;
