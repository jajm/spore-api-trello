#!/usr/bin/perl

use Modern::Perl;
use Data::Dumper;
use JSON::PP;
use Getopt::Long;
use HTML::TreeBuilder;

my $conf = {
    name => "Trello",
    base_url => "https://api.trello.com",
    formats => [ "json" ],
    version => "0.1",
    methods => {}
};

my @method_transformations = (
    sub { $_[0] =~ s/_actions_idaction($|_)/_action$1/ },
    sub { $_[0] =~ s/_boards_board_id($|_)/_board$1/ },
    sub { $_[0] =~ s/^put_boards$/put_board/ },
    sub { $_[0] =~ s/^put_boards$/put_board/ },
    sub { $_[0] =~ s/_cards_card_id_or_shortlink($|_)/_card$1/ },
    sub { $_[0] =~ s/^put_cards$/put_card/ },
    sub { $_[0] =~ s/_checklists_idchecklist($|_)/_checklist$1/ },
    sub { $_[0] =~ s/^put_checklists$/put_checklist/ },
    sub { $_[0] =~ s/^put_/modify_/ },
    sub { $_[0] =~ s/^post_/new_/ },
    sub { $_[0] =~ s/_(\w)/\U$1\E/g },
);


my $weight_table = {
    name => 0,
    version => 1,
    base_url => 2,
    formats => 3,
    methods => 4,

    path => 0,
    method => 1,
    required_params => 2,
    optional_params => 3,
    _params_infos => 4,
};

my $output = 'trello.json';
my $verbose = 0;

GetOptions(
    'output|o:s' => \$output,
    'verbose|v' => \$verbose,
);

my @names = qw(action board card checklist list member notification organization
search token type);

my $weight = 0;
foreach my $name (@names) {
    my $url = "https://trello.com/docs/api/$name/index.html";
    $verbose and say "Retrieving $url...";
    my $tree = HTML::TreeBuilder->new_from_url($url);
    my $global_section = $tree->look_down(id => $name);
    foreach my $section ($global_section->look_down(_tag => 'div', class => 'section', sub { $_[0]->id ne $name})) {
        # Get method and path
        my $h2 = $section->look_down(_tag => 'h2');
        $h2->objectify_text;
        my $method = $h2->look_down(_tag => '~text')->attr('text');
        $method =~ s/\s//g;
        $h2->deobjectify_text;
        my $path = $h2->look_down(_tag => 'span')->as_text;
        $verbose and say "  $method $path";

        # Get arguments
        my $arguments_list = $section->look_down(_tag => 'li', sub { $_[0]->as_text =~ /^Arguments/ })->look_down(_tag => 'ul');
        my (@required_params, @optional_params, %params_infos);
        if ($arguments_list) {
            foreach my $list_item ($arguments_list->look_down(_tag => 'li', sub { $_[0]->parent == $arguments_list })) {
                # Argument name
                my $argument = $list_item->look_down(_tag => 'span')->as_text;

                # Required?
                my $required = ($list_item->as_text =~ /(required)/);

                # Default value
                my $default_node = $list_item->look_down(_tag => 'strong', sub { $_[0]->as_text eq "Default:" });
                my $default_value;
                if ($default_node) {
                    $default_value = $default_node->parent->look_down(_tag => 'span')->as_text;
                }

                # Valid values
                my $valid_node = $list_item->look_down(_tag => 'strong', sub { $_[0]->as_text eq "Valid Values:" });
                my @valid_values;
                my $allow_multiple;
                if ($valid_node) {
                    my $valid_list = $valid_node->parent->look_down(_tag => 'ul');
                    if ($valid_list) {
                        foreach ($valid_list->look_down(_tag => 'span')) {
                            push @valid_values, $_->as_text;
                        }
                        # Multiple values allowed?
                        $allow_multiple = ($valid_node->parent->as_text =~ /or a comma-separated list of:/);
                    }
                }

                if ($required) {
                    push @required_params, $argument;
                } else {
                    push @optional_params, $argument;
                }

                if (defined $default_value or @valid_values or $allow_multiple) {
                    $params_infos{$argument} = {};
                    if (defined $default_value) {
                        $params_infos{$argument}->{default_value} = $default_value;
                    }
                    if (@valid_values) {
                        $params_infos{$argument}->{valid_values} = \@valid_values;
                    }
                    if (defined $allow_multiple) {
                        $params_infos{$argument}->{allow_multiple} = $allow_multiple ? \1 : \0;
                    }
                }
            }
        }

        # Add missing required params from path
        while ($path =~ /\[(.*?)\]/g) {
            my $param = $1;
            $param =~ s| |_|g;
            if (0 == grep /^$param$/, @required_params) {
                push @required_params, $param;
            }
        }

        # Add required 'key' parameter
        push @required_params, 'key';

        # Add optional 'token' parameter, if not already present in
        # required and optional parameters.
        if (0 == grep /^token$/, @required_params and 0 == grep /^token$/, @optional_params) {
            push @optional_params, 'token';
        }

        # Build a unique Perl sub name for this method.
        my $method_name = $method . $path;
        $method_name =~ s|/1/|_|;
        $method_name =~ s|\[(.*?)\]|$1|g;
        $method_name =~ s|/|_|g;
        $method_name =~ s| |_|g;
        $method_name = lc($method_name);

        foreach my $t (@method_transformations) {
            $t->($method_name);
        }

        # Update weight table
        $weight_table->{$method_name} = $weight++;

        # Modify the path so it's understable by SPORE
        $path =~ s| |_|g;
        $path =~ s|\[(.*?)\]|:$1|g;

        # Update conf
        $conf->{methods}->{$method_name} = {
            method => $method,
            path => $path,
            required_params => \@required_params,
            optional_params => \@optional_params,
        };

        # Add extra informations not used by SPORE
        if (%params_infos) {
            $conf->{methods}->{$method_name}->{_params_infos} = \%params_infos;
        }
    }
    $verbose and say "";
}

my $json = JSON::PP->new->utf8(1)->pretty(1)->sort_by(sub {
    my $wt = $weight_table;
    my $a = defined $wt->{$JSON::PP::a} ? $wt->{$JSON::PP::a} : 0;
    my $b = defined $wt->{$JSON::PP::b} ? $wt->{$JSON::PP::b} : 0;
    $a <=> $b
} )->encode($conf);

if ($output eq '-') {
    print $json;
    print "\n";
} else {
    open my $fh, '>', $output or die "Can't open $output: $!";
    print $fh $json;
    $verbose and print "Output written to $output.\n";
}

