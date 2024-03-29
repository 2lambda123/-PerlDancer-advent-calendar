package danceradvent;
use Dancer2;
use DateTime;
use Pod::POM;
use Pod::POM::View::InlineHTML;

use Dancer::Plugin::Feed;
use Dancer::Plugin::MobileDevice;

use URI;
use POSIX qw/strftime/;
our $VERSION = '0.1';

my $article_dir = Dancer::FileUtils::path(
    setting('appdir'), 'public', 'articles'
);

# an ignore_trailing slash option is cooking already
get '/feed/:year/' => sub { redirect uri_for('/feed/'. params->{year} ) };
get '/:year/'      => sub { redirect uri_for('/' . params->{year} ) };
get '/:year/:day/' => sub {
    redirect uri_for('/'. params->{year} . '/' . params->{day} )
};

hook 'before_template' => sub {
    my $tokens = shift;
    $tokens->{uri_base} = request->base->path eq '/' ? '' : request->base->path;
};

hook 'before' => sub {
    my @date = localtime(time);
    my $current_year = $date[5] + 1900;

    if (!setting('render_future')) {
        if (($date[4] + 1) < 12 && ($current_year > setting('start_year'))) {
            $current_year--;
        }
        if (params->{year} && params->{year} > $current_year) {
            debug("we need to redirect to $current_year");
            redirect("/$current_year");
        }
    }

    vars->{current_year} = $current_year;
};

get '/' => sub {
    my $redirect_year = vars->{current_year};
    # Starting with this year, go back until we find a year that has
    # an article for the 24th (even if it's not yet viewable, because
    # we could be early-December on a Twelve Days of Dancer year where
    # we only have articles from 13th-24th, but we still want to go to
    # this year's page so it's clear we do have upcoming articles)
    while (!_article_exists($redirect_year, 24)) {
        $redirect_year--;
    }
    debug "going to $redirect_year";
    redirect("/$redirect_year");
};

get '/notyet' => sub {
    template 'notyet';
};

get '/archive' => sub {
    my $today = DateTime->today();

    my $year = $today->year;
    $year-- unless $today->month == 12;
     
    my @all_entries;
    for my $y (config->{start_year} .. $year ) { 
        # Set year param only as _get_entries uses it
        params->{year} = $y;
        
        # Fetch the titles of all the posts so the template can provide a list
        # of named posts. Exclude the today's article, to keep the mystery ;)
        push @all_entries, grep { $_->{issued} != $today } _get_entries(params->{year});
    }

    return template 'archive' => { 
        all_entries => \@all_entries,
        year => $year,
    };
};

get '/:year' => sub {
    return send_error( "this is not a valid year", 404 )
      unless _control_date( params->{year} );

    my $articles = _articles_viewable(params->{year});
    
    # Fetch the titles of all the posts so the template can provide a list
    # of named posts. Exclude the today's article, to keep the mystery ;)
    my $today = DateTime->today();
    my @all_entries 
        = grep { $_->{issued} != $today } _get_entries(params->{year});

    # If this year doesn't have an article for day 1, but does for day 13, then
    # it's a cut-down "Twelve Days of Dancer" year where we didn't have enough
    # articles to fill the whole thing, so we use a different template in that
    # case.
    my $template = _article_exists(params->{year}, 1)
        ? 'index' : 'index-twelvedays';

    # Assemble a list of other years which have viewable articles for links:
    my @other_years;
    for my $year (config->{start_year} .. (localtime)[5] + 1900) {
        push @other_years, $year 
            if $year != params->{year} && 
                grep { $_->{viewable} } @{ _articles_viewable($year) };
    }

    return template $template => { 
        year => params->{year}, 
        articles => $articles, 
        all_entries => \@all_entries,
        other_years => \@other_years,
    };
};

get '/feed/:year' => sub {
    my @entries = map { $_->[0] }
        sort { $b->[1] <=> $a->[1] }
        map { [ $_, $_->{issued}->ymd('') ] } _get_entries(params->{year});
  
    create_feed(
        format  => 'rss',
        title   => 'Dancer Advent Calendar ' . params->{year},
        link    => request->base,
        entries => \@entries,
    );
};



get '/:year/:day' => sub {
    # XXX better 404 page for this
    return send_error( "this is not valid date", 404 )
      unless _control_date( params->{year}, params->{day} );

    my $year = params->{year};
    my $day  = params->{day};

    return template 'notyet' unless ( _article_viewable( $year, $day ) );

    my ($pod_file) = _article_exists( $year, $day );

    return send_error( "No such article", 404 ) if ( !defined $pod_file );

    my ($title, $html) = _pod_to_html($pod_file);

    return template article => {
        title => $title || "Perl Dancer Advent Calendar",
        year  => $year,
        day   => $day,
        content => $html
    };
};



sub _pod_to_html {
    my $pod_file = shift;

    my $article_pod = Dancer::FileUtils::read_file_content($pod_file);

    my $parser = Pod::POM->new;
    my $pom    = $parser->parse($article_pod);

    # fetch the title
    my $title = $pom->head1;

    if ( $title && $title->[0] ) {
        $title = $title->[0]->title;
    }

    my $html = Pod::POM::View::InlineHTML->print($pom);
    return ($title, $html);
}

sub _articles_viewable {
    my $year = shift;

    # randomly chosen
    my @days = (
        19, 12, 6, 4,  13, 22, 17, 3, 23, 21, 9,  16,
        24, 11, 5, 10, 15, 20, 7,  8, 14, 1,  18, 2,
    );

    my @articles;
    
    # If this year is a twelve days of Dancer cut-down year, i.e. we have no
    # article for the 1st but do for the 13th, then exclude the previous 12
    # days:
    if (!_article_exists($year, 1) && _article_exists($year, 13)) {
        @days = grep { $_ >= 13 } @days;
    }

    for my $day (@days) {

        push @articles, {

            # _article_viewable should check if there is an article available
            # and if 201012$day <= $current_date
            viewable => _article_viewable( $year, $day ),

            #viewable => $day <= 5 ? 1 : 0, # TODO: fixme
            day => $day,
        };
    }
    return \@articles;
}

sub _article_viewable {
    my ($year, $day) = @_;
    my $date = sprintf "%04d12%02d", $year, $day;
    # using gmtime
    my $today = strftime "%Y%m%d", gmtime(time);

    if (setting('render_future')) {
        $today = sprintf "%04d12%02d", $year, 24;
    }

    if($date <= $today) {
        return defined _article_exists($year, $day);
    }

    return undef
}

sub _control_date {
    my ( $year, $day ) = @_;
    my $valid = 1;
    $valid = 0 if $year !~ /^\d{4}$/;
    $valid = 0 if ( $day && $day !~ /^\d\d?$/ );
    return $valid;
}

sub _article_exists {
    my ($year, $day) = @_;

    my ($file) = glob("$article_dir/${year}/${day}-*.pod");
    if(defined $file) {
        return $file;
    }

    return undef;
}

sub _get_entries {
    my $year = shift;
    my @entries;
    my $articles = _articles_viewable($year);
    $articles = [sort {$a->{day} <=> $b->{day}} @$articles];
    
    foreach my $article (@$articles ) {
        next unless $article->{viewable};
        my ($pod_file) = _article_exists( params->{year}, $article->{day} );
        my ( $title, $html ) = _pod_to_html($pod_file);
        my $permalink = URI->new( request->base );
        $permalink->path( params->{year} . '/' . $article->{day} );
        push @entries,
          {
            title    => $title,
            content  => $html,
            link     => $permalink,
            category => 'perl',
            issued   => DateTime->new(
                year  => $year,
                month => 12,
                day   => $article->{day}
            ),
            year     => $year
          };
    }
    return @entries;
 }
true;
