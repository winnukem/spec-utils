use warnings;
use strict;

use Plack::Request;
use Plack::Builder;

use File::Spec::Functions qw/catdir catfile/;
use FindBin;
use lib::abs catdir('..', 'lib');

use Plack::Util;
use Plack::MIME;
use HTTP::Date;
use File::Slurp qw/read_file write_file/;
use Try::Tiny;
use File::Modified;

use App::Graph;
use Local::Config qw(load_config merge_config_keys update_config_keys);
use Local::Config::Format qw(check_priority_format check_status_format detect_and_check_format);

my %config;
sub read_config
{
   open my $fh, '<', $_[0] or die "Can't read config file.\n";
   while (<$fh>) {
      s/#.*+\Z//;
      next if /\A\h*+\Z/;
      if (/\A\h*+(\w++)\h*+=\h*+([\w\/\-\.]++)\h*+\Z/) {
         my ($key, $value) = ($1, $2);
         if (exists $config{$key}) {
            warn "Option $key has been already set.\n"
         }
         $config{$key} = $value
      } else {
         warn "Error in config string '$_'. Can't parse. Skipping.\n"
      }
   }
   close $fh;
}

my $ppid = getppid();
read_config catfile $FindBin::Bin, '.config';
my $priority = load_config $config{priority_config_file};
unless ($priority) {
   warn "Can't read priority config file.\n";
   kill "SIGKILL", $ppid;
}
my $status   = load_config $config{status_config_file};
unless ($status) {
   warn "Can't read status config file.\n";
   kill "SIGKILL", $ppid;
}

if (!check_status_format($status) || !check_priority_format($priority)) {
   warn "Wrong file format.\n";
   kill "SIGKILL", $ppid;
}
merge_config_keys $config{config}, $priority;
merge_config_keys $config{config}, $status;

my $cmonitor = File::Modified->new(files => [@config{qw/priority_config_file status_config_file/}]);
delete $config{priority_config_file};
delete $config{status_config_file};

$config{functions} = [];
$config{async}     = 0;
$config{keep_dot}  = 0;
$config{issues}    = 0;

$config{out}        .= $$;
$config{cache_file} .= $$;
my $cache_default = $config{cache};


sub return_403
{
   return [403, ['Content-Type' => 'text/plain', 'Content-Length' => 9], ['forbidden']];
}

sub return_404
{
   return [404, ['Content-Type' => 'text/plain', 'Content-Length' => 9], ['not found']];
}

sub return_500
{
   return [500, ['Content-Type' => 'text/plain', 'Content-Length' => 37], ["Internal error. Can't generate image."]];
}

sub generate_image
{
   if (my (@cf) = $cmonitor->changed) {
      try {
             my $new_config;
             foreach (@cf) {
                my $c = load_config $_;
                if (detect_and_check_format($c)) {
                   merge_config_keys $new_config, $c;
                } else {
                   warn "Incorrect configuration update. Will use previous.\n";
                }
             }
             update_config_keys $config{config}, $new_config;
             warn "Loading updated configuration @cf\n";
      } catch {
         warn "Can't load updated configuration\n"
      };
      $cmonitor->update();
   }

   my $fail = 0;
   try {
      $config{cache} = $cache_default;
      run(\%config)
   } catch {
      warn "Can't generate image: $_\n";
      $fail = 1;
   };

   if ($fail) {
      return -1
   }

   if ($config{format} eq 'svg') {
      my $filename = $config{out} . '.' . $config{format};
      my $svg = read_file($filename);

      my $link_begin;
      my $link_begin_end = qq|">\n|;
      if ($_[0] eq 'image') {
         $link_begin = qq|<a xlink:href="/graph/image?func=|;
      } elsif ($_[0] eq 'page') {
         $link_begin = qq|<a xlink:href="/graph?func=|;
      }
      my $link_end   = qq|</a>\n|;

      while ($svg =~ /<g id="node/g) {
         my $begin = $-[0];
         my $pos = pos($svg);

         my $end = index($svg, "</g>\n", $begin) + 5;
         my $area = substr($svg, $begin, $end - $begin);
         my ($title) = $area =~ m!<title>([a-zA-Z_]\w++)</title>!;
         next unless $title;
         my $link = $link_begin . $title . $link_begin_end;

         substr($svg, $end, 0, $link_end);
         substr($svg, $begin, 0, $link);
         pos($svg) = $pos + length($link) + length($link_end);
      }

      write_file($filename, $svg);
   }

   return 0
}

my $image = sub {
   my $env = shift;
   my %original = (format => $config{format}, functions => $config{functions});

   my $req = Plack::Request->new($env);
   my $res = $req->new_response(200);

   if ($req->param('fmt')) {
      if ($config{format} =~ m/(png)|(svg)|(jpg)|(jpeg)/) {
         $config{format} = $req->param('fmt')
      } else {
         return return_403
      }
   }
   if ($req->param('func')) {
      $config{functions} = [ split(/,/, $req->param('func')) ]
   }

   return return_500
      if generate_image('image');

   my $file = $config{out} . '.' . $config{format};
   $config{format} = $original{format};
   $config{functions} = $original{functions};

   open my $fh, "<:raw", $file
      or return return_500;

   my @stat = stat $file;
   my $mime = Plack::MIME->mime_type($file);
   Plack::Util::set_io_path($fh, Cwd::realpath($file));

   return [
      200,
      [
         'Content-Type'   => $mime,
         'Content-Length' => $stat[7],
         'Last-Modified'  => HTTP::Date::time2str( $stat[9] )
      ],
      $fh,
   ];

};

my $page = sub {
   my $env = shift;
   my %original = (format => $config{format}, functions => $config{functions});
   my $html = <<'HTML';
<!DOCTYPE html>
<html>
   <head>
      <meta charset="UTF-8">
      <title>Functions graph</title>

      <!--<link rel="stylesheet" href="http://cdn.leafletjs.com/leaflet/v0.7.7/leaflet.css" /> -->
      <link rel="stylesheet" href="http://openlayers.org/en/v3.14.2/css/ol.css" type="text/css">
      <script src="http://openlayers.org/en/v3.14.2/build/ol.js" type="text/javascript"></script>

      <style>
         #map {
            width: 100%;
            height: 100%;
         };
         html, body {
            height: 100%;
            margin: 0px;
         }
      </style>
   </head>

   <body>
      <div id="map"></div>

      <script>
         var IMG_URL = "/graph/image###FUNC###";
         var img = new Image();
         var graph;
         img.onload = function() {
            var extent = [0, 0, img.width, img.height];
            var projection = new ol.proj.Projection({
               code: 'graph-image',
               units: 'pixels',
               extent: extent
            });

            var graph = new ol.Map({
               layers: [
                  new ol.layer.Image({
                     source: new ol.source.ImageStatic({
                        url: IMG_URL,
                        projection: projection,
                        imageExtent: extent
                     })
                  })
               ],
               target: 'map',
               view: new ol.View({
                  projection: projection,
                  center: ol.extent.getCenter(extent),
                  zoom: 2,
                  maxZoom: 8
               })
            });
         }
         img.src = IMG_URL;
      </script>
   </body>

</html>
HTML

   my $req = Plack::Request->new($env);
   my $res = $req->new_response(200);

   if ($req->param('fmt')) {
      if ($config{format} =~ m/(png)|(svg)|(jpg)|(jpeg)/) {
         $config{format} = $req->param('fmt')
      } else {
         return return_403
      }
   }
   if ($req->param('func')) {
      $config{functions} = [ split(/,/, $req->param('func')) ]
   }

   my $func = '';
   if ($req->param('func')) {
      $func = '?func=' . $req->param('func');
   }
   $html =~ s/###FUNC###/$func/;
   $res->body($html);

   $config{format} = $original{format};
   $config{functions} = $original{functions};

   return $res->finalize();
};

my $main_app = builder {
   mount '/graph/image' => builder { $image };
   mount '/graph'       => builder { $page };
   mount '/map'         => builder { $page };
   mount '/favicon.ico' => builder { \&return_404 };
   mount '/'            => builder { \&return_404 };
};
