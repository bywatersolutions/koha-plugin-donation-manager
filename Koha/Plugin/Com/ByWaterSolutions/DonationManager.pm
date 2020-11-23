package Koha::Plugin::Com::ByWaterSolutions::DonationManager;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Context;
use C4::Auth;
use Koha::Patron;
use Koha::DateUtils qw(dt_from_string);

use Cwd qw(abs_path);
use Mojo::JSON qw(decode_json);;
use URI::Escape qw(uri_unescape);
use LWP::UserAgent;

our $VERSION = "{VERSION}";
our $MINIMUM_VERSION = "{MINIMUM_VERSION}";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Donation Manager',
    author          => 'Kyle M Hall',
    date_authored   => '2020-07-07',
    date_updated    => "1900-01-01",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Track and manage patron donations from Koha.',
};

sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    my $self = $class->SUPER::new($args);

    return $self;
}

sub report {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('output') ) {
        $self->report_step1();
    }
    else {
        $self->report_step2();
    }
}

sub tool {
    my ( $self, $args ) = @_;

    my $cgi = $self->{'cgi'};

    my $borrowernumber = $cgi->param('borrowernumber');
    my $action = $cgi->param('action') || q{};

    if ( $action eq "add" ) {
        $self->tool_add();
    } elsif ( $action eq "delete" ) {
        my $id = $cgi->param('id');
        $self->tool_delete({ borrowernumber => $borrowernumber, id => $id });
    } else {
        $self->tool_display({ borrowernumber => $borrowernumber });
    }
}

sub intranet_head {
    my ( $self ) = @_;

    return q{};
}

sub intranet_js {
    my ( $self ) = @_;

    return q|
        <script>
            $(document).ready( function() {
                let href = $("a:contains('Details')").attr('href');
                if ( href ) {
                  let parts = href.split("=");
                  let borrowernumber = parts[1];
                  $( "#menu ul" ).append( $( "<li id='donations-tab'><a href='/cgi-bin/koha/plugins/run.pl?class=Koha%3A%3APlugin%3A%3ACom%3A%3AByWaterSolutions%3A%3ADonationManager&method=tool&borrowernumber=" + borrowernumber + "'>Donations</a></li>" ) ); 
                }
            });
        </script>
    |;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template({ file => 'configure.tt' });

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            enable_opac_payments => $self->retrieve_data('enable_opac_payments'),
            foo             => $self->retrieve_data('foo'),
            bar             => $self->retrieve_data('bar'),
            last_upgraded   => $self->retrieve_data('last_upgraded'),
        );

        $self->output_html( $template->output() );
    }
    else {
        $self->store_data(
            {
                enable_opac_payments => $cgi->param('enable_opac_payments'),
                foo                => $cgi->param('foo'),
                bar                => $cgi->param('bar'),
                last_configured_by => C4::Context->userenv->{'number'},
            }
        );
        $self->go_home();
    }
}

sub install() {
    my ( $self, $args ) = @_;

    return C4::Context->dbh->do( "
        CREATE TABLE IF NOT EXISTS donations (
            `id` int(11) NOT NULL AUTO_INCREMENT,
            `borrowernumber` INT( 11 ) NULL DEFAULT NULL,
            `amount` decimal(28,6) NULL DEFAULT NULL,
            `type` varchar(80) NULL DEFAULT NULL,
            `branchcode` VARCHAR( 10 ) NULL DEFAULT NULL,
            `biblionumber` int(11) NULL DEFAULT NULL,
            `itemnumber` int(11) NULL DEFAULT NULL,
            `created_on` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id),
            KEY `borrowernumber` (borrowernumber),
            KEY `branchcode` (`branchcode`),
            KEY `biblionumber` (`biblionumber`),
            KEY `itemnumber` (`itemnumber`),
            CONSTRAINT `dnbn` FOREIGN KEY (`borrowernumber`) REFERENCES `borrowers` (`borrowernumber`) ON DELETE SET NULL ON UPDATE CASCADE,
            CONSTRAINT `dnbranch` FOREIGN KEY (`branchcode`) REFERENCES `branches` (`branchcode`) ON DELETE SET NULL ON UPDATE CASCADE,
            CONSTRAINT `dnbibno` FOREIGN KEY (`biblionumber`) REFERENCES `biblio` (`biblionumber`) ON DELETE SET NULL ON UPDATE CASCADE,
            CONSTRAINT `dnitmno` FOREIGN KEY (`itemnumber`) REFERENCES `items` (`itemnumber`) ON DELETE SET NULL ON UPDATE CASCADE
        ) ENGINE=InnoDB  DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    " );
}

sub upgrade {
    my ( $self, $args ) = @_;

    return 1;
}

sub uninstall() {
    my ( $self, $args ) = @_;

    return C4::Context->dbh->do("DROP TABLE IF EXISTS donations");
}

sub report_step1 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({ file => 'report-step1.tt' });

    $self->output_html( $template->output() );
}

sub report_step2 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({ file => 'something.tt' });

    print $template->output();
}

sub tool_display {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({ file => 'tool-display.tt' });

    my $borrowernumber = $cgi->param('borrowernumber');

    my $patron = Koha::Patrons->find( $borrowernumber );

    my $branch_limit = C4::Context->userenv->{"branch"};

    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare("SELECT * FROM donations WHERE borrowernumber = ? AND branchcode = ?");
    $sth->execute( $borrowernumber, $branch_limit );

    my @donations;
    while ( my $d = $sth->fetchrow_hashref() ) {
        $d->{biblio} = Koha::Biblios->find( $d->{biblionumber} ) if $d->{biblionumber};
        $d->{item} = Koha::Items->find( $d->{itemnumber} ) if $d->{itemnumber};
        push( @donations, $d );
    }

    $template->param(
        patron => $patron,
        donations => \@donations,
    );

    $self->output_html( $template->output() );
}

sub tool_add {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $borrowernumber = $cgi->param('borrowernumber') || undef;
    my $amount = $cgi->param('amount') || undef;
    my $type = $cgi->param('type') || undef;
    my $branchcode = C4::Context->userenv->{'branch'} || undef;
    my $biblionumber = $cgi->param('biblionumber') || undef;
    my $barcode = $cgi->param('barcode') || undef;
    my $date = dt_from_string($cgi->param('date')) || dt_from_string;
    $date = $date->ymd;

    my $biblio = Koha::Biblios->find($biblionumber);
    $biblionumber = undef unless $biblio;

    my $item = Koha::Items->find({ barcode => $barcode });
    my $itemnumber = $item ? $item->id : undef;
    $biblionumber = $item ? $item->biblionumber : $biblionumber;

    my $dbh = C4::Context->dbh;
    my $query = "INSERT INTO donations ( borrowernumber, amount, type, branchcode, biblionumber, itemnumber, created_on ) VALUES ( ?, ?, ?, ?, ?, ?, ? )";
    my $sth = $dbh->prepare($query);
    $sth->execute( $borrowernumber, $amount, $type, $branchcode, $biblionumber, $itemnumber, $date );

    $self->tool_display($args);
}

sub tool_delete {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $dbh = C4::Context->dbh;
    $dbh->do("DELETE FROM donations WHERE id = ?", undef, $args->{id});

    $self->tool_display($args);
}

sub tool_step2 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({ file => 'tool-step2.tt' });

    my $borrowernumber = C4::Context->userenv->{'number'};
    my $borrower = Koha::Patrons->find( $borrowernumber );
    $template->param( 'victim' => $borrower->unblessed() );
    $template->param( 'victim' => $borrower );

    $borrower->firstname('Bob')->store;

    my $dbh = C4::Context->dbh;

    my $table = $self->get_qualified_table_name('mytable');

    my $sth   = $dbh->prepare("SELECT DISTINCT(borrowernumber) FROM $table");
    $sth->execute();
    my @victims;
    while ( my $r = $sth->fetchrow_hashref() ) {
        my $brw = Koha::Patrons->find( $r->{'borrowernumber'} )->unblessed();
        push( @victims, ( $brw ) );
    }
    $template->param( 'victims' => \@victims );

    $dbh->do( "INSERT INTO $table ( borrowernumber ) VALUES ( ? )",
        undef, ($borrowernumber) );

    $self->output_html( $template->output() );
}

## API methods
# If your plugin implements API routes, then the 'api_routes' method needs
# to be implemented, returning valid OpenAPI 2.0 paths serialized as a hashref.
# It is a good practice to actually write OpenAPI 2.0 path specs in JSON on the
# plugin and read it here. This allows to use the spec for mainline Koha later,
# thus making this a good prototyping tool.

sub api_routes {
    my ( $self, $args ) = @_;

    my $spec_str = $self->mbf_read('openapi.json');
    my $spec     = decode_json($spec_str);

    return $spec;
}

sub api_namespace {
    my ( $self ) = @_;
    
    return 'donationmanager';
}

1;
