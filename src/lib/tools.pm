# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id$

# Sympa - SYsteme de Multi-Postage Automatique
#
# Copyright (c) 1997, 1998, 1999 Institut Pasteur & Christophe Wolfhugel
# Copyright (c) 1997, 1998, 1999, 2000, 2001, 2002, 2003, 2004, 2005,
# 2006, 2007, 2008, 2009, 2010, 2011 Comite Reseau des Universites
# Copyright (c) 2011, 2012, 2013, 2014 GIP RENATER
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package tools;

use strict;
use warnings;
#use Cwd qw();
use Digest::MD5;
use Encode::Guess;           ## Useful when encoding should be guessed
use Encode::MIME::Header;    # for 'MIME-Q' encoding
use English;                 # FIXME: drop $MATCH and $PREMATCH usage
use File::Copy::Recursive;
use File::Find;
use HTML::StripScripts::Parser;
use MIME::Base64 qw();
use MIME::Decoder;
use MIME::EncWords;
use POSIX qw();
use Proc::ProcessTable;
use Scalar::Util qw();
use Sys::Hostname qw();
use Text::LineFold;
use Time::HiRes qw();
use Time::Local qw();
use if (5.008 < $] && $] < 5.016), qw(Unicode::CaseFold fc);
use if (5.016 <= $]), qw(feature fc);

use Sympa::Alarm;
use Conf;
use Sympa::Constants;
use Sympa::Language;
use Sympa::List;
use Sympa::ListDef;
use Sympa::LockedFile;
use Log;
use Sympa::Regexps;
use Sympa::Robot;
use SDM;
use tools;

## global var to store a CipherSaber object
my $cipher;

my $separator =
    "------- CUT --- CUT --- CUT --- CUT --- CUT --- CUT --- CUT -------";

## Sets owner and/or access rights on a file.
sub set_file_rights {
    my %param = @_;
    my ($uid, $gid);

    if ($param{'user'}) {
        unless ($uid = (getpwnam($param{'user'}))[2]) {
            Log::do_log('err', "User %s can't be found in passwd file",
                $param{'user'});
            return undef;
        }
    } else {
        #
        # "A value of -1 is interpreted by most systems to leave that value unchanged".
        $uid = -1;
    }
    if ($param{'group'}) {
        unless ($gid = (getgrnam($param{'group'}))[2]) {
            Log::do_log('err', "Group %s can't be found", $param{'group'});
            return undef;
        }
    } else {
        #
        # "A value of -1 is interpreted by most systems to leave that value unchanged".
        $gid = -1;
    }
    unless (chown($uid, $gid, $param{'file'})) {
        Log::do_log('err', "Can't give ownership of file %s to %s.%s: %m",
            $param{'file'}, $param{'user'}, $param{'group'});
        return undef;
    }
    if ($param{'mode'}) {
        unless (chmod($param{'mode'}, $param{'file'})) {
            Log::do_log('err', "Can't change rights of file %s: %m",
                $Conf::Conf{'db_name'});
            return undef;
        }
    }
    return 1;
}

## Returns an HTML::StripScripts::Parser object built with  the parameters
## provided as arguments.
sub _create_xss_parser {
    my %parameters = @_;
    my $robot      = $parameters{'robot'};
    Log::do_log('debug3', '(%s)', $robot);

    my $http_host_re = Conf::get_robot_conf($robot, 'http_host');
    $http_host_re =~ s/([^\s\w\x80-\xFF])/\\$1/g;
    my $hss = HTML::StripScripts::Parser->new(
        {   Context  => 'Document',
            AllowSrc => 1,
            Rules    => {'*' => {src => qr{^http://$http_host_re},},},
        }
    );
    return $hss;
}

## Returns sanitized version (using StripScripts) of the string provided as
## argument.
sub sanitize_html {
    my %parameters = @_;
    my $robot      = $parameters{'robot'};
    Log::do_log('debug3', '(string=%s, robot=%s)',
        $parameters{'string'}, $robot);

    unless (defined $parameters{'string'}) {
        Log::do_log('err', 'No string provided');
        return undef;
    }

    my $hss = _create_xss_parser('robot' => $robot);
    unless (defined $hss) {
        Log::do_log('err', 'Can\'t create StripScript parser');
        return undef;
    }
    my $string = $hss->filter_html($parameters{'string'});
    return $string;
}

## Returns sanitized version (using StripScripts) of the content of the file
## whose path is provided as argument.
sub sanitize_html_file {
    my %parameters = @_;
    my $robot      = $parameters{'robot'};
    Log::do_log('debug3', '(file=%s, robot=%s)', $parameters{'file'}, $robot);

    unless (defined $parameters{'file'}) {
        Log::do_log('err', 'No path to file provided');
        return undef;
    }

    my $hss = _create_xss_parser('robot' => $robot);
    unless (defined $hss) {
        Log::do_log('err', 'Can\'t create StripScript parser');
        return undef;
    }
    $hss->parse_file($parameters{'file'});
    return $hss->filtered_document;
}

## Sanitize all values in the hash $var, starting from $level
sub sanitize_var {
    my %parameters = @_;
    my $robot      = $parameters{'robot'};
    Log::do_log('debug3', '(var=%s, level=%s, robot=%s)',
        $parameters{'var'}, $parameters{'level'}, $robot);
    unless (defined $parameters{'var'}) {
        Log::do_log('err', 'Missing var to sanitize');
        return undef;
    }
    unless (defined $parameters{'htmlAllowedParam'}
        && $parameters{'htmlToFilter'}) {
        Log::do_log(
            'err',
            'Missing var *** %s *** %s *** to ignore',
            $parameters{'htmlAllowedParam'},
            $parameters{'htmlToFilter'}
        );
        return undef;
    }
    my $level = $parameters{'level'};
    $level |= 0;

    if (ref($parameters{'var'})) {
        if (ref($parameters{'var'}) eq 'ARRAY') {
            foreach my $index (0 .. $#{$parameters{'var'}}) {
                if (   (ref($parameters{'var'}->[$index]) eq 'ARRAY')
                    || (ref($parameters{'var'}->[$index]) eq 'HASH')) {
                    sanitize_var(
                        'var'              => $parameters{'var'}->[$index],
                        'level'            => $level + 1,
                        'robot'            => $robot,
                        'htmlAllowedParam' => $parameters{'htmlAllowedParam'},
                        'htmlToFilter'     => $parameters{'htmlToFilter'},
                    );
                } elsif (defined $parameters{'var'}->[$index]) {
                    # preserve numeric flags.
                    $parameters{'var'}->[$index] =
                        escape_html($parameters{'var'}->[$index])
                        unless Scalar::Util::looks_like_number(
                        $parameters{'var'}->[$index]);
                }
            }
        } elsif (ref($parameters{'var'}) eq 'HASH') {
            foreach my $key (keys %{$parameters{'var'}}) {
                if (   (ref($parameters{'var'}->{$key}) eq 'ARRAY')
                    || (ref($parameters{'var'}->{$key}) eq 'HASH')) {
                    sanitize_var(
                        'var'              => $parameters{'var'}->{$key},
                        'level'            => $level + 1,
                        'robot'            => $robot,
                        'htmlAllowedParam' => $parameters{'htmlAllowedParam'},
                        'htmlToFilter'     => $parameters{'htmlToFilter'},
                    );
                } elsif (defined $parameters{'var'}->{$key}) {
                    unless ($parameters{'htmlAllowedParam'}{$key}
                        or $parameters{'htmlToFilter'}{$key}) {
                        # preserve numeric flags.
                        $parameters{'var'}->{$key} =
                            escape_html($parameters{'var'}->{$key})
                            unless Scalar::Util::looks_like_number(
                            $parameters{'var'}->{$key});
                    }
                    if ($parameters{'htmlToFilter'}{$key}) {
                        $parameters{'var'}->{$key} = sanitize_html(
                            'string' => $parameters{'var'}->{$key},
                            'robot'  => $robot
                        );
                    }
                }

            }
        }
    } else {
        Log::do_log('err', 'Variable is neither a hash nor an array');
        return undef;
    }
    return 1;
}

## Sorts the list of addresses by domain name
## Input : users hash
## Sort by domain.
sub sortbydomain {
    my ($x, $y) = @_;
    $x = join('.', reverse(split(/[@\.]/, $x)));
    $y = join('.', reverse(split(/[@\.]/, $y)));
    #print "$x $y\n";
    $x cmp $y;
}

## Sort subroutine to order files in sympa spool by date
sub by_date {
    my @a_tokens = split /\./, ($a || '');
    my @b_tokens = split /\./, ($b || '');

    ## File format : list@dom.date.pid
    my $a_time = $a_tokens[$#a_tokens - 1] || 0;
    my $b_time = $b_tokens[$#b_tokens - 1] || 0;

    return $a_time <=> $b_time;

}

## Safefork does several tries before it gives up.
## Do 3 trials and wait 10 seconds * $i between each.
## Exit with a fatal error is fork failed after all
## tests have been exhausted.
sub safefork {
    my ($i, $pid);

    my $err;
    for ($i = 1; $i < 4; $i++) {
        my ($pid) = fork;
        return $pid if (defined($pid));

        $err = $ERRNO;
        Log::do_log('warn', 'Cannot create new process in safefork: %s',
            $err);
        ## FIXME:should send a mail to the listmaster
        sleep(10 * $i);
    }
    die sprintf 'Exiting because cannot create new process in safefork: %s',
        $err;
    ## No return.
}

####################################################
# checkcommand
####################################################
# Checks for no command in the body of the message.
# If there are some command in it, it return true
# and send a message to $sender
#
# IN : -$msg (+): ref(MIME::Entity) - message to check
#      -$sender (+): the sender of $msg
#      -$robot (+) : robot
#
# OUT : -1 if there are some command in $msg
#       -0 else
#
######################################################
sub checkcommand {
    my ($msg, $sender, $robot) = @_;

    my ($avoid, $i);

    my $hdr = $msg->head;

    ## Check for commands in the subject.
    my $subject = $msg->head->get('Subject');

    Log::do_log('debug3', '(msg->head->get(subject) %s, %s)',
        $subject, $sender);

    if ($subject) {
        if ($Conf::Conf{'misaddressed_commands_regexp'}
            && ($subject =~
                /^$Conf::Conf{'misaddressed_commands_regexp'}\b/im)) {
            return 1;
        }
    }

    return 0 if ($#{$msg->body} >= 5);    ## More than 5 lines in the text.

    foreach $i (@{$msg->body}) {
        if ($Conf::Conf{'misaddressed_commands_regexp'}
            && ($i =~ /^$Conf::Conf{'misaddressed_commands_regexp'}\b/im)) {
            return 1;
        }

        ## Control is only applied to first non-blank line
        last unless $i =~ /^\s*$/;
    }
    return 0;
}

## return a hash from the edit_list_conf file
sub load_edit_list_conf {
    Log::do_log('debug2', '(%s)', @_);
    my $list = shift;

    my $robot = $list->{'domain'};
    my $file;
    my $conf;

    return undef
        unless $file = tools::search_fullpath($list, 'edit_list.conf');

    unless (open(FILE, $file)) {
        Log::do_log('info', 'Unable to open config file %s', $file);
        return undef;
    }

    my $error_in_conf;
    my $roles_regexp =
        'listmaster|privileged_owner|owner|editor|subscriber|default';
    while (<FILE>) {
        next if /^\s*(\#.*|\s*)$/;

        if (/^\s*(\S+)\s+(($roles_regexp)\s*(,\s*($roles_regexp))*)\s+(read|write|hidden)\s*$/i
            ) {
            my ($param, $role, $priv) = ($1, $2, $6);
            my @roles = split /,/, $role;
            foreach my $r (@roles) {
                $r =~ s/^\s*(\S+)\s*$/$1/;
                if ($r eq 'default') {
                    $error_in_conf = 1;
                    Log::do_log('notice', '"default" is no more recognised');
                    foreach
                        my $set ('owner', 'privileged_owner', 'listmaster') {
                        $conf->{$param}{$set} = $priv;
                    }
                    next;
                }
                $conf->{$param}{$r} = $priv;
            }
        } else {
            Log::do_log(
                'info',
                'Unknown parameter in %s (Ignored) %s',
                "$Conf::Conf{'etc'}/edit_list.conf", $_
            );
            next;
        }
    }

    if ($error_in_conf) {
        tools::send_notify_to_listmaster($robot, 'edit_list_error', [$file]);
    }

    close FILE;
    return $conf;
}

## return a hash from the edit_list_conf file
sub load_create_list_conf {
    my $robot = shift;

    my $file;
    my $conf;

    $file = tools::search_fullpath($robot, 'create_list.conf');
    unless ($file) {
        Log::do_log(
            'info',
            'Unable to read %s',
            Sympa::Constants::DEFAULTDIR . '/create_list.conf'
        );
        return undef;
    }

    unless (open(FILE, $file)) {
        Log::do_log('info', 'Unable to open config file %s', $file);
        return undef;
    }

    while (<FILE>) {
        next if /^\s*(\#.*|\s*)$/;

        if (/^\s*(\S+)\s+(read|hidden)\s*$/i) {
            $conf->{$1} = lc($2);
        } else {
            Log::do_log(
                'info',
                'Unknown parameter in %s (Ignored) %s',
                "$Conf::Conf{'etc'}/create_list.conf", $_
            );
            next;
        }
    }

    close FILE;
    return $conf;
}

sub _add_topic {
    my ($name, $title) = @_;
    my $topic = {};

    my @tree = split '/', $name;
    if ($#tree == 0) {
        return {'title' => $title};
    } else {
        $topic->{'sub'}{$name} =
            _add_topic(join('/', @tree[1 .. $#tree]), $title);
        return $topic;
    }
}

sub get_list_list_tpl {
    my $robot = shift;

    my $list_conf;
    my $list_templates;
    unless ($list_conf = load_create_list_conf($robot)) {
        return undef;
    }

    foreach my $dir (
        reverse
        @{tools::get_search_path($robot, subdir => 'create_list_templates')})
    {
        if (opendir(DIR, $dir)) {
        LOOP_FOREACH_TEMPLATE:
            foreach my $template (sort grep (!/^\./, readdir(DIR))) {
                my $status = $list_conf->{$template}
                    || $list_conf->{'default'};
                next if $status eq 'hidden';

                $list_templates->{$template}{'path'} = $dir;

                # Look for a comment.tt2.
                # Check old style locale first then canonic language and its
                # fallbacks.
                my $lang = Sympa::Language->instance->get_lang;
                my $comment_tt2;
                foreach my $l (
                    Sympa::Language::lang2oldlocale($lang),
                    Sympa::Language::implicated_langs($lang)
                    ) {
                    next unless $l;
                    $comment_tt2 =
                        $dir . '/' . $template . '/' . $l . '/comment.tt2';
                    if (-r $comment_tt2) {
                        $list_templates->{$template}{'comment'} =
                            $comment_tt2;
                        next LOOP_FOREACH_TEMPLATE;
                    }
                }
                $comment_tt2 = $dir . '/' . $template . '/comment.tt2';
                if (-r $comment_tt2) {
                    $list_templates->{$template}{'comment'} = $comment_tt2;
                }
            }
            closedir(DIR);
        }
    }

    return ($list_templates);
}

#copy a directory and its content
sub copy_dir {
    my $dir1 = shift;
    my $dir2 = shift;
    Log::do_log('debug', 'Copy directory %s to %s', $dir1, $dir2);

    unless (-d $dir1) {
        Log::do_log('err',
            'Directory source "%s" doesn\'t exist. Copy impossible', $dir1);
        return undef;
    }
    return (File::Copy::Recursive::dircopy($dir1, $dir2));
}

#delete a directory and its content
sub del_dir {
    Log::do_log('debug3', '(%s)', @_);
    my $dir = shift;

    if (opendir DIR, $dir) {
        for (readdir DIR) {
            next if /^\.{1,2}$/;
            my $path = "$dir/$_";
            unlink $path   if -f $path;
            del_dir($path) if -d $path;
        }
        closedir DIR;
        unless (rmdir $dir) {
            Log::do_log('err', 'Unable to delete directory %s: %m', $dir);
        }
    } else {
        Log::do_log(
            'err',
            'Unable to open directory %s to delete the files it contains: %m',
            $dir
        );
    }
}

#to be used before creating a file in a directory that may not exist already.
sub mk_parent_dir {
    my $file = shift;
    $file =~ /^(.*)\/([^\/])*$/;
    my $dir = $1;

    return 1 if (-d $dir);
    mkdir_all($dir, 0755);
}

## Recursively create directory and all parent directories
sub mkdir_all {
    my ($path, $mode) = @_;
    my $status = 1;

    ## Change umask to fully apply modes of mkdir()
    my $saved_mask = umask;
    umask 0000;

    return undef if ($path eq '');
    return 1 if (-d $path);

    ## Compute parent path
    my @token = split /\//, $path;
    pop @token;
    my $parent_path = join '/', @token;

    unless (-d $parent_path) {
        unless (mkdir_all($parent_path, $mode)) {
            $status = undef;
        }
    }

    if (defined $status) {    ## Don't try if parent dir could not be created
        unless (mkdir($path, $mode)) {
            $status = undef;
        }
    }

    ## Restore umask
    umask $saved_mask;

    return $status;
}

# shift file renaming it with date. If count is defined, keep $count file and
# unlink others
sub shift_file {
    my $file  = shift;
    my $count = shift;
    Log::do_log('debug', '(%s, %s)', $file, $count);

    unless (-f $file) {
        Log::do_log('info', 'Unknown file %s', $file);
        return undef;
    }

    my @date = localtime(time);
    my $file_extention = POSIX::strftime("%Y:%m:%d:%H:%M:%S", @date);

    unless (rename($file, $file . '.' . $file_extention)) {
        Log::do_log('err', 'Cannot rename file %s to %s.%s',
            $file, $file, $file_extention);
        return undef;
    }
    if ($count) {
        $file =~ /^(.*)\/([^\/])*$/;
        my $dir = $1;

        unless (opendir(DIR, $dir)) {
            Log::do_log('err', 'Cannot read dir %s', $dir);
            return ($file . '.' . $file_extention);
        }
        my $i = 0;
        foreach my $oldfile (reverse(sort (grep (/^$file\./, readdir(DIR)))))
        {
            $i++;
            if ($count lt $i) {
                if (unlink($oldfile)) {
                    Log::do_log('info', 'Unlink %s', $oldfile);
                } else {
                    Log::do_log('info', 'Unable to unlink %s', $oldfile);
                }
            }
        }
    }
    return ($file . '.' . $file_extention);
}

=over

=item get_mtime ( $file )

Gets modification time of the file.

Parameter:

=over

=item $file

Full path of file.

=back

Returns:

Modification time as UNIX time.
If the file is not found or is not readable, returns C<POSIX::INT_MIN>.
In case of other error, returns C<undef>.

=back

=cut

sub get_mtime {
    my $file = shift;
    die 'Missing parameter $file' unless $file;

    return POSIX::INT_MIN() unless -e $file and -r $file;

    my @stat = stat $file;
    return $stat[9];
}

sub get_templates_list {
    Log::do_log('debug3', '(%s, %s, %s, %s)', @_);
    my $type    = shift;
    my $robot   = shift;
    my $list    = shift;
    my $options = shift;

    my $listdir;

    unless (($type eq 'web') || ($type eq 'mail')) {
        Log::do_log('info', 'Internal error incorrect parameter');
    }

    my $distrib_dir = Sympa::Constants::DEFAULTDIR . '/' . $type . '_tt2';
    my $site_dir    = $Conf::Conf{'etc'} . '/' . $type . '_tt2';
    my $robot_dir = $Conf::Conf{'etc'} . '/' . $robot . '/' . $type . '_tt2';

    my @try;

    ## The 'ignore_global' option allows to look for files at list level only
    unless ($options->{'ignore_global'}) {
        push @try, $distrib_dir;
        push @try, $site_dir;
        push @try, $robot_dir;
    }

    if (defined $list) {
        $listdir = $list->{'dir'} . '/' . $type . '_tt2';
        push @try, $listdir;
    } else {
        $listdir = '';
    }

    my $i = 0;
    my $tpl;

    foreach my $dir (@try) {
        next unless opendir(DIR, $dir);
        foreach my $file (grep (!/^\./, readdir(DIR))) {
            ## Subdirectory for a lang
            if (-d $dir . '/' . $file) {
                my $lang = $file;
                next unless opendir(LANGDIR, $dir . '/' . $lang);
                foreach my $file (grep (!/^\./, readdir(LANGDIR))) {
                    next unless ($file =~ /\.tt2$/);
                    if ($dir eq $distrib_dir) {
                        $tpl->{$file}{'distrib'}{$lang} =
                            $dir . '/' . $lang . '/' . $file;
                    }
                    if ($dir eq $site_dir) {
                        $tpl->{$file}{'site'}{$lang} =
                            $dir . '/' . $lang . '/' . $file;
                    }
                    if ($dir eq $robot_dir) {
                        $tpl->{$file}{'robot'}{$lang} =
                            $dir . '/' . $lang . '/' . $file;
                    }
                    if ($dir eq $listdir) {
                        $tpl->{$file}{'list'}{$lang} =
                            $dir . '/' . $lang . '/' . $file;
                    }
                }
                closedir LANGDIR;

            } else {
                next unless ($file =~ /\.tt2$/);
                if ($dir eq $distrib_dir) {
                    $tpl->{$file}{'distrib'}{'default'} = $dir . '/' . $file;
                }
                if ($dir eq $site_dir) {
                    $tpl->{$file}{'site'}{'default'} = $dir . '/' . $file;
                }
                if ($dir eq $robot_dir) {
                    $tpl->{$file}{'robot'}{'default'} = $dir . '/' . $file;
                }
                if ($dir eq $listdir) {
                    $tpl->{$file}{'list'}{'default'} = $dir . '/' . $file;
                }
            }
        }
        closedir DIR;
    }
    return ($tpl);

}

# return the path for a specific template
sub get_template_path {
    Log::do_log('debug2', '(%s, %s. %s, %s, %s, %s)', @_);
    my $type  = shift;
    my $robot = shift;
    my $scope = shift;
    my $tpl   = shift;
    my $lang  = shift || 'default';
    my $list  = shift;

    my $subdir = '';
    # canonicalize language name which may be old-style locale name.
    unless ($lang eq 'default') {
        my $oldlocale = Sympa::Language::lang2oldlocale($lang);
        unless ($oldlocale eq $lang) {
            $subdir = Sympa::Language::canonic_lang($lang);
            unless ($subdir) {
                Log::do_log('info', 'Internal error incorrect parameter');
                return undef;
            }
        }
    }

    unless ($type eq 'web' or $type eq 'mail') {
        Log::do_log('info', 'Internal error incorrect parameter');
        return undef;
    }

    my $dir;
    if ($scope eq 'list') {
        unless (ref $list eq 'Sympa::List') {
            Log::do_log('err', 'Missing parameter "list"');
            return undef;
        }
        $dir = $list->{'dir'};
    } elsif ($scope eq 'robot') {
        $dir = $Conf::Conf{'etc'} . '/' . $robot;
    } elsif ($scope eq 'site') {
        $dir = $Conf::Conf{'etc'};
    } elsif ($scope eq 'distrib') {
        $dir = Sympa::Constants::DEFAULTDIR;
    } else {
        return undef;
    }

    $dir .= '/' . $type . '_tt2';
    $dir .= '/' . $subdir if length $subdir;
    return $dir . '/' . $tpl;
}

## Make a multipart/alternative, a singlepart
sub as_singlepart {
    Log::do_log('debug2', '');
    my ($msg, $preferred_type, $loops) = @_;
    my $done = 0;
    $loops++;

    unless (defined $msg) {
        Log::do_log('err', "Undefined message parameter");
        return undef;
    }

    if ($loops > 4) {
        Log::do_log('err', 'Could not change multipart to singlepart');
        return undef;
    }

    if ($msg->effective_type() =~ /^$preferred_type$/) {
        $done = 1;
    } elsif ($msg->effective_type() =~ /^multipart\/alternative/) {
        foreach my $part ($msg->parts) {
            if (($part->effective_type() =~ /^$preferred_type$/)
                || (   ($part->effective_type() =~ /^multipart\/related$/)
                    && $part->parts
                    && ($part->parts(0)->effective_type() =~
                        /^$preferred_type$/)
                )
                ) {
                ## Only keep the first matching part
                $msg->parts([$part]);
                $msg->make_singlepart();
                $done = 1;
                last;
            }
        }
    } elsif ($msg->effective_type() =~ /multipart\/signed/) {
        my @parts = $msg->parts();
        ## Only keep the first part
        $msg->parts([$parts[0]]);
        $msg->make_singlepart();

        $done ||= as_singlepart($msg, $preferred_type, $loops);

    } elsif ($msg->effective_type() =~ /^multipart/) {
        foreach my $part ($msg->parts) {

            next unless (defined $part);    ## Skip empty parts

            if ($part->effective_type() =~ /^multipart\/alternative/) {
                if (as_singlepart($part, $preferred_type, $loops)) {
                    $msg->parts([$part]);
                    $msg->make_singlepart();
                    $done = 1;
                }
            }
        }
    }

    return $done;
}

## Escape characters before using a string within a regexp parameter
## Escaped characters are : @ $ [ ] ( ) ' ! '\' * . + ?
sub escape_regexp {
    my $s = shift;
    my @escaped =
        ("\\", '@', '$', '[', ']', '(', ')', "'", '!', '*', '.', '+', '?');
    my $backslash = "\\";    ## required in regexp

    foreach my $escaped_char (@escaped) {
        $s =~ s/$backslash$escaped_char/\\$escaped_char/g;
    }

    return $s;
}

# Escape weird characters
# FIXME: Should not use.
sub escape_chars {
    my $s          = shift;
    my $except     = shift;                            ## Exceptions
    my $ord_except = ord $except if defined $except;

    ## Escape chars
    ##  !"#$%&'()+,:;<=>?[] AND accented chars
    ## escape % first
    foreach my $i (
        0x25,
        0x20 .. 0x24,
        0x26 .. 0x2c,
        0x3a .. 0x3f,
        0x5b, 0x5d,
        0x80 .. 0x9f,
        0xa0 .. 0xff
        ) {
        next if defined $ord_except and $i == $ord_except;
        my $hex_i = sprintf "%lx", $i;
        $s =~ s/\x$hex_i/%$hex_i/g;
    }
    ## Special traetment for '/'
    $s =~ s/\//%a5/g unless defined $except and $except eq '/';

    return $s;
}

## Escape shared document file name
## Q-decode it first
sub escape_docname {
    my $filename = shift;
    my $except   = shift;    ## Exceptions

    ## Q-decode
    $filename = MIME::EncWords::decode_mimewords($filename);

    ## Decode from FS encoding to utf-8
    #$filename = Encode::decode($Conf::Conf{'filesystem_encoding'}, $filename);

    ## escapesome chars for use in URL
    return escape_chars($filename, $except);
}

## Convert from Perl unicode encoding to UTF8
sub unicode_to_utf8 {
    my $s = shift;

    if (Encode::is_utf8($s)) {
        return Encode::encode_utf8($s);
    }

    return $s;
}

## This applies recursively to a data structure
## The transformation subroutine is passed as a ref
sub recursive_transformation {
    my ($var, $subref) = @_;

    return unless (ref($var));

    if (ref($var) eq 'ARRAY') {
        foreach my $index (0 .. $#{$var}) {
            if (ref($var->[$index])) {
                recursive_transformation($var->[$index], $subref);
            } else {
                $var->[$index] = &{$subref}($var->[$index]);
            }
        }
    } elsif (ref($var) eq 'HASH') {
        foreach my $key (sort keys %{$var}) {
            if (ref($var->{$key})) {
                recursive_transformation($var->{$key}, $subref);
            } else {
                $var->{$key} = &{$subref}($var->{$key});
            }
        }
    }

    return;
}

## Q-Encode web file name
sub qencode_filename {
    my $filename = shift;

    ## We don't use MIME::Words here because it does not encode properly
    ## Unicode
    ## Check if string is already Q-encoded first
    ## Also check if the string contains 8bit chars
    unless ($filename =~ /\=\?UTF-8\?/
        || $filename =~ /^[\x00-\x7f]*$/) {

        ## Don't encode elements such as .desc. or .url or .moderate
        ## or .extension
        my $part = $filename;
        my ($leading, $trailing);
        $leading  = $1 if ($part =~ s/^(\.desc\.)//);    ## leading .desc
        $trailing = $1 if ($part =~ s/((\.\w+)+)$//);    ## trailing .xx

        my $encoded_part = MIME::EncWords::encode_mimewords(
            $part,
            Charset    => 'utf8',
            Encoding   => 'q',
            MaxLineLen => 1000,
            Minimal    => 'NO'
        );

        $filename = $leading . $encoded_part . $trailing;
    }

    return $filename;
}

## Q-Decode web file name
sub qdecode_filename {
    my $filename = shift;

    ## We don't use MIME::Words here because it does not encode properly
    ## Unicode
    ## Check if string is already Q-encoded first
    #if ($filename =~ /\=\?UTF-8\?/) {
    $filename = Encode::encode_utf8(Encode::decode('MIME-Q', $filename));
    #}

    return $filename;
}

## Unescape weird characters
sub unescape_chars {
    my $s = shift;

    $s =~ s/%a5/\//g;    ## Special traetment for '/'
    foreach my $i (0x20 .. 0x2c, 0x3a .. 0x3f, 0x5b, 0x5d, 0x80 .. 0x9f,
        0xa0 .. 0xff) {
        my $hex_i = sprintf "%lx", $i;
        my $hex_s = sprintf "%c",  $i;
        $s =~ s/%$hex_i/$hex_s/g;
    }

    return $s;
}

sub escape_html {
    my $s = shift;
    return $s unless defined $s;

    $s =~ s/\"/\&quot\;/gm;
    $s =~ s/\</&lt\;/gm;
    $s =~ s/\>/&gt\;/gm;

    return $s;
}

sub unescape_html {
    my $s = shift;
    return $s unless defined $s;

    $s =~ s/\&quot\;/\"/g;
    $s =~ s/&lt\;/\</g;
    $s =~ s/&gt\;/\>/g;

    return $s;
}

sub tmp_passwd {
    my $email = shift;

    return (
        'init'
            . substr(
            Digest::MD5::md5_hex(join('/', $Conf::Conf{'cookie'}, $email)), -8
            )
    );
}

# Check sum used to authenticate communication from wwsympa to sympa
# DEPRECATED: No longer used: This is moved to upgrade_send_spool.pl to be
# used for migrating old spool.
#sub sympa_checksum($rcpt);

BEGIN { eval 'use Crypt::CipherSaber'; }

# create a cipher
sub ciphersaber_installed {
    return $cipher if defined $cipher;

    if ($Crypt::CipherSaber::VERSION) {
        $cipher = Crypt::CipherSaber->new($Conf::Conf{'cookie'});
    } else {
        $cipher = '';
    }
    return $cipher;
}

# create a cipher
sub cookie_changed {
    my $current = shift;
    my $changed = 1;
    if (-f "$Conf::Conf{'etc'}/cookies.history") {
        unless (open COOK, "$Conf::Conf{'etc'}/cookies.history") {
            Log::do_log('err', 'Unable to read %s/cookies.history',
                $Conf::Conf{'etc'});
            return undef;
        }
        my $oldcook = <COOK>;
        close COOK;

        my @cookies = split(/\s+/, $oldcook);

        if ($cookies[$#cookies] eq $current) {
            Log::do_log('debug2', 'Cookie is stable');
            $changed = 0;
#	}else{
#	    push @cookies, $current ;
#	    unless (open COOK, ">$Conf::Conf{'etc'}/cookies.history") {
#		Log::do_log('err', 'Unable to create %s/cookies.history', $Conf::Conf{'etc'}) ;
#		return undef ;
#	    }
#	    printf COOK "%s",join(" ",@cookies) ;
#
#	    close COOK;
        }
        return $changed;
    } else {
        my $umask = umask 037;
        unless (open COOK, ">$Conf::Conf{'etc'}/cookies.history") {
            umask $umask;
            Log::do_log('err', 'Unable to create %s/cookies.history',
                $Conf::Conf{'etc'});
            return undef;
        }
        umask $umask;
        chown [getpwnam(Sympa::Constants::USER)]->[2],
            [getgrnam(Sympa::Constants::GROUP)]->[2],
            "$Conf::Conf{'etc'}/cookies.history";
        print COOK "$current ";
        close COOK;
        return (0);
    }
}

## encrypt a password
sub crypt_password {
    my $inpasswd = shift;

    ciphersaber_installed();
    return $inpasswd unless $cipher;
    return ("crypt." . MIME::Base64::encode($cipher->encrypt($inpasswd)));
}

## decrypt a password
sub decrypt_password {
    my $inpasswd = shift;
    Log::do_log('debug2', '(%s)', $inpasswd);

    return $inpasswd unless ($inpasswd =~ /^crypt\.(.*)$/);
    $inpasswd = $1;

    ciphersaber_installed();
    unless ($cipher) {
        Log::do_log('info',
            'Password seems crypted while CipherSaber is not installed !');
        return $inpasswd;
    }
    return ($cipher->decrypt(MIME::Base64::decode($inpasswd)));
}

sub load_mime_types {
    my $types = {};

    my @localisation = (
        '/etc/mime.types',            '/usr/local/apache/conf/mime.types',
        '/etc/httpd/conf/mime.types', 'mime.types'
    );

    foreach my $loc (@localisation) {
        next unless (-r $loc);

        unless (open(CONF, $loc)) {
            print STDERR "load_mime_types: unable to open $loc\n";
            return undef;
        }
    }

    while (<CONF>) {
        next if /^\s*\#/;

        if (/^(\S+)\s+(.+)\s*$/i) {
            my ($k, $v) = ($1, $2);

            my @extensions = split / /, $v;

            ## provides file extention, given the content-type
            if ($#extensions >= 0) {
                $types->{$k} = $extensions[0];
            }

            foreach my $ext (@extensions) {
                $types->{$ext} = $k;
            }
            next;
        }
    }

    close FILE;
    return $types;
}

sub split_mail {
    my $message  = shift;
    my $pathname = shift;
    my $dir      = shift;

    my $head     = $message->head;
    my $body     = $message->body;
    my $encoding = $head->mime_encoding;

    if ($message->is_multipart
        || ($message->mime_type eq 'message/rfc822')) {

        for (my $i = 0; $i < $message->parts; $i++) {
            split_mail($message->parts($i), $pathname . '.' . $i, $dir);
        }
    } else {
        my $fileExt;

        if ($head->mime_attr("content_type.name") =~ /\.(\w+)\s*\"*$/) {
            $fileExt = $1;
        } elsif ($head->recommended_filename =~ /\.(\w+)\s*\"*$/) {
            $fileExt = $1;
        } else {
            my $mime_types = load_mime_types();

            $fileExt = $mime_types->{$head->mime_type};
            my $var = $head->mime_type;
        }

        ## Store body in file
        unless (open OFILE, ">$dir/$pathname.$fileExt") {
            Log::do_log('err', 'Unable to create %s/%s.%s: %m',
                $dir, $pathname, $fileExt);
            return undef;
        }

        if ($encoding =~
            /^(binary|7bit|8bit|base64|quoted-printable|x-uu|x-uuencode|x-gzip64)$/
            ) {
            open TMP, ">$dir/$pathname.$fileExt.$encoding";
            $message->print_body(\*TMP);
            close TMP;

            open BODY, "$dir/$pathname.$fileExt.$encoding";

            my $decoder = MIME::Decoder->new($encoding);
            unless (defined $decoder) {
                Log::do_log('err', 'Cannot create decoder for %s', $encoding);
                return undef;
            }
            $decoder->decode(\*BODY, \*OFILE);
            close BODY;
            unlink "$dir/$pathname.$fileExt.$encoding";
        } else {
            $message->print_body(\*OFILE);
        }
        close(OFILE);
        printf "\t-------\t Create file %s\n", $pathname . '.' . $fileExt;

        ## Delete files created twice or more (with Content-Type.name and
        ## Content-Disposition.filename)
        $message->purge;
    }

    return 1;
}

# Note: this would be moved to incoming pipeline package.
sub virus_infected {
    Log::do_log('debug2', '%s)', @_);
    my $message = shift;

    my $entity = $message->as_entity;
    my $file   = $message->{'messagekey'};

    unless ($Conf::Conf{'antivirus_path'}) {
        Log::do_log('debug', 'Sympa not configured to scan virus in message');
        return 0;
    }
    my ($name) = reverse split /\//, $file;
    my $work_dir = $Conf::Conf{'tmpdir'} . '/antivirus';

    unless (-d $work_dir or mkdir $work_dir, 0755) {
        Log::do_log('err', 'Unable to create tmp antivirus directory %s: %m',
            $work_dir);
        return undef;
    }

    $work_dir = $Conf::Conf{'tmpdir'} . '/antivirus/' . $name;

    unless (-d $work_dir or mkdir $work_dir, 0755) {
        Log::do_log('err', 'Unable to create tmp antivirus directory %s: %m',
            $work_dir);
        return undef;
    }

    ## Call the procedure of splitting mail
    unless (tools::split_mail($entity, 'msg', $work_dir)) {
        Log::do_log('err', 'Could not split mail %s', $entity);
        return undef;
    }

    my $virusfound = 0;
    my $error_msg;
    my $result;

    ## McAfee
    if ($Conf::Conf{'antivirus_path'} =~ /\/uvscan$/) {

        # impossible to look for viruses with no option set
        unless ($Conf::Conf{'antivirus_args'}) {
            Log::do_log('err', 'Missing "antivirus_args" in sympa.conf');
            return undef;
        }

        open(ANTIVIR,
            "$Conf::Conf{'antivirus_path'} $Conf::Conf{'antivirus_args'} $work_dir |"
        );

        while (<ANTIVIR>) {
            $result .= $_;
            chomp $result;
            if (   (/^\s*Found the\s+(.*)\s*virus.*$/i)
                || (/^\s*Found application\s+(.*)\.\s*$/i)) {
                $virusfound = $1;
            }
        }
        close ANTIVIR;

        my $status = $? >> 8;

        ## uvscan status =12 or 13 (*256) => virus
        if (($status == 13) || ($status == 12)) {
            $virusfound ||= "unknown";
        }

        ## Meaning of the codes
        ##  12 : The program tried to clean a file, and that clean failed for
        ##  some reason and the file is still infected.
        ##  13 : One or more viruses or hostile objects (such as a Trojan
        ##  horse, joke program,  or  a  test file) were found.
        ##  15 : The programs self-check failed; the program might be infected
        ##  or damaged.
        ##  19 : The program succeeded in cleaning all infected files.

        $error_msg = $result
            if ($status != 0
            && $status != 12
            && $status != 13
            && $status != 19);

        ## Trend Micro
    } elsif ($Conf::Conf{'antivirus_path'} =~ /\/vscan$/) {

        open(ANTIVIR,
            "$Conf::Conf{'antivirus_path'} $Conf::Conf{'antivirus_args'} $work_dir |"
        );

        while (<ANTIVIR>) {
            if (/Found virus (\S+) /i) {
                $virusfound = $1;
            }
        }
        close ANTIVIR;

        my $status = $CHILD_ERROR / 256;

        ## uvscan status = 1 | 2 (*256) => virus
        if ((($status == 1) or ($status == 2)) and not($virusfound)) {
            $virusfound = "unknown";
        }

        ## F-Secure
    } elsif ($Conf::Conf{'antivirus_path'} =~ /\/fsav$/) {
        my $dbdir = $PREMATCH;

        # impossible to look for viruses with no option set
        unless ($Conf::Conf{'antivirus_args'}) {
            Log::do_log('err', 'Missing "antivirus_args" in sympa.conf');
            return undef;
        }

        open(ANTIVIR,
            "$Conf::Conf{'antivirus_path'} --databasedirectory $dbdir $Conf::Conf{'antivirus_args'} $work_dir |"
        );

        while (<ANTIVIR>) {

            if (/infection:\s+(.*)/) {
                $virusfound = $1;
            }
        }

        close ANTIVIR;

        my $status = $CHILD_ERROR / 256;

        ## fsecure status =3 (*256) => virus
        if (($status == 3) and not($virusfound)) {
            $virusfound = "unknown";
        }
    } elsif ($Conf::Conf{'antivirus_path'} =~ /f-prot\.sh$/) {

        Log::do_log('debug2', 'F-prot is running');

        open(ANTIVIR,
            "$Conf::Conf{'antivirus_path'} $Conf::Conf{'antivirus_args'} $work_dir |"
        );

        while (<ANTIVIR>) {

            if (/Infection:\s+(.*)/) {
                $virusfound = $1;
            }
        }

        close ANTIVIR;

        my $status = $CHILD_ERROR / 256;

        Log::do_log('debug2', 'Status: ' . $status);

        ## f-prot status =3 (*256) => virus
        if (($status == 3) and not($virusfound)) {
            $virusfound = "unknown";
        }
    } elsif ($Conf::Conf{'antivirus_path'} =~ /kavscanner/) {

        # impossible to look for viruses with no option set
        unless ($Conf::Conf{'antivirus_args'}) {
            Log::do_log('err', 'Missing "antivirus_args" in sympa.conf');
            return undef;
        }

        open(ANTIVIR,
            "$Conf::Conf{'antivirus_path'} $Conf::Conf{'antivirus_args'} $work_dir |"
        );

        while (<ANTIVIR>) {
            if (/infected:\s+(.*)/) {
                $virusfound = $1;
            } elsif (/suspicion:\s+(.*)/i) {
                $virusfound = $1;
            }
        }
        close ANTIVIR;

        my $status = $CHILD_ERROR / 256;

        ## uvscan status =3 (*256) => virus
        if (($status >= 3) and not($virusfound)) {
            $virusfound = "unknown";
        }

        ## Sophos Antivirus... by liuk@publinet.it
    } elsif ($Conf::Conf{'antivirus_path'} =~ /\/sweep$/) {

        # impossible to look for viruses with no option set
        unless ($Conf::Conf{'antivirus_args'}) {
            Log::do_log('err', 'Missing "antivirus_args" in sympa.conf');
            return undef;
        }

        open(ANTIVIR,
            "$Conf::Conf{'antivirus_path'} $Conf::Conf{'antivirus_args'} $work_dir |"
        );

        while (<ANTIVIR>) {
            if (/Virus\s+(.*)/) {
                $virusfound = $1;
            }
        }
        close ANTIVIR;

        my $status = $CHILD_ERROR / 256;

        ## sweep status =3 (*256) => virus
        if (($status == 3) and not($virusfound)) {
            $virusfound = "unknown";
        }

        ## Clam antivirus
    } elsif ($Conf::Conf{'antivirus_path'} =~ /\/clamd?scan$/) {

        open(ANTIVIR,
            "$Conf::Conf{'antivirus_path'} $Conf::Conf{'antivirus_args'} $work_dir |"
        );

        my $result;
        while (<ANTIVIR>) {
            $result .= $_;
            chomp $result;
            if (/^\S+:\s(.*)\sFOUND$/) {
                $virusfound = $1;
            }
        }
        close ANTIVIR;

        my $status = $CHILD_ERROR / 256;

        ## Clamscan status =1 (*256) => virus
        if (($status == 1) and not($virusfound)) {
            $virusfound = "unknown";
        }

        $error_msg = $result
            if ($status != 0 && $status != 1);

    }

    ## Error while running antivir, notify listmaster
    if ($error_msg) {
        tools::send_notify_to_listmaster(
            '*',
            'virus_scan_failed',
            {   'filename'  => $file,
                'error_msg' => $error_msg
            }
        );
    }

    ## if debug mode is active, the working directory is kept
    unless ($main::options{'debug'}) {
        opendir(DIR, ${work_dir});
        my @list = readdir(DIR);
        closedir(DIR);
        foreach (@list) {
            my $nbre = unlink("$work_dir/$_");
        }
        rmdir($work_dir);
    }

    return $virusfound;

}

## subroutines for epoch and human format date processings

## convert an epoch date into a readable date scalar
sub adate {

    my $epoch = $_[0];
    my @date  = localtime($epoch);
    my $date  = POSIX::strftime("%e %a %b %Y  %H h %M min %S s", @date);

    return $date;
}

## Return the epoch date corresponding to the last midnight before date given
## as argument.
sub get_midnight_time {

    my $epoch = $_[0];
    Log::do_log('debug3', 'Getting midnight time for: %s', $epoch);
    my @date = localtime($epoch);
    return $epoch - $date[0] - $date[1] * 60 - $date[2] * 3600;
}

## convert a human format date into an epoch date
sub epoch_conv {

    my $arg = $_[0];             # argument date to convert
    my $time = $_[1] || time;    # the epoch current date

    Log::do_log('debug3', '(%s, %d)', $arg, $time);

    my $result;

    # decomposition of the argument date
    my $date;
    my $duration;
    my $op;

    if ($arg =~ /^(.+)(\+|\-)(.+)$/) {
        $date     = $1;
        $duration = $3;
        $op       = $2;
    } else {
        $date     = $arg;
        $duration = '';
        $op       = '+';
    }

    #conversion
    $date = date_conv($date, $time);
    $duration = duration_conv($duration, $date);

    if   ($op eq '+') { $result = $date + $duration; }
    else              { $result = $date - $duration; }

    return $result;
}

sub date_conv {

    my $arg  = $_[0];
    my $time = $_[1];

    if (($arg eq 'execution_date')) {    # execution date
        return time;
    }

    if ($arg =~ /^\d+$/) {               # already an epoch date
        return $arg;
    }

    if ($arg =~ /^(\d\d\d\dy)(\d+m)?(\d+d)?(\d+h)?(\d+min)?(\d+sec)?$/) {
        # absolute date

        my @date = ($6, $5, $4, $3, $2, $1);
        foreach my $part (@date) {
            $part =~ s/[a-z]+$// if $part;
            $part ||= 0;
            $part += 0;
        }
        $date[3] = 1 if $date[3] == 0;
        $date[4]-- if $date[4] != 0;
        $date[5] -= 1900;

        return Time::Local::timelocal(@date);
    }

    return time;
}

sub duration_conv {

    my $arg        = $_[0];
    my $start_date = $_[1];

    return 0 unless $arg;

    my @date =
        ($arg =~ /(\d+y)?(\d+m)?(\d+w)?(\d+d)?(\d+h)?(\d+min)?(\d+sec)?$/i);
    foreach my $part (@date) {
        $part =~ s/[a-z]+$// if $part;    ## Remove trailing units
        $part ||= 0;
    }

    my $duration =
        $date[6] + 60 *
        ($date[5] +
            60 * ($date[4] + 24 * ($date[3] + 7 * $date[2] + 365 * $date[0]))
        );

    # specific processing for the months because their duration varies
    my @months = (
        31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
        31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
    );
    my $start = (defined $start_date) ? (localtime($start_date))[4] : 0;
    for (my $i = 0; $i < $date[1]; $i++) {
        $duration += $months[$start + $i] * 60 * 60 * 24;
    }

    return $duration;
}

=head3 Finding config files and templates

=over 4

=item search_fullpath ( $that, $name, [ opt => val, ...] )

    # To get file name for global site
    $file = tools::search_fullpath('*', $name);
    # To get file name for a robot
    $file = tools::search_fullpath($robot_id, $name);
    # To get file name for a family
    $file = tools::search_fullpath($family, $name);
    # To get file name for a list
    $file = tools::search_fullpath($list, $name);

Look for a file in the list > robot > site > default locations.

Possible values for options:
    order     => 'all'
    subdir    => directory ending each path
    lang      => language
    lang_only => if paths without lang subdirectory would be omitted

Returns full path of target file C<I<root>/I<subdir>/I<lang>/I<name>>
or C<I<root>/I<subdir>/I<name>>.
I<root> is the location determined by target object $that.
I<subdir> and I<lang> are optional.
If C<lang_only> option is set, paths without I<lang> subdirectory is omitted.

=back

=cut

sub search_fullpath {
    Log::do_log('debug3', '(%s, %s, %s)', @_);
    my $that    = shift;
    my $name    = shift;
    my %options = @_;

    my (@try, $default_name);

    ## template refers to a language
    ## => extend search to default tpls
    ## FIXME: family path precedes to list path.  Is it appropriate?
    if ($name =~ /^(\S+)\.([^\s\/]+)\.tt2$/) {
        $default_name = $1 . '.tt2';
        @try =
            map { ($_ . '/' . $name, $_ . '/' . $default_name) }
            @{get_search_path($that, %options)};
    } else {
        @try =
            map { $_ . '/' . $name } @{get_search_path($that, %options)};
    }

    my @result;
    foreach my $f (@try) {
##        if (-l $f) {
##            my $realpath = Cwd::abs_path($f);    # follow symlink
##            next unless $realpath and -r $realpath;
##        } elsif (!-r $f) {
##            next;
##        }
        next unless -r $f;
        Log::do_log('debug3', 'Name: %s; file %s', $name, $f);

        if ($options{'order'} and $options{'order'} eq 'all') {
            push @result, $f;
        } else {
            return $f;
        }
    }
    if ($options{'order'} and $options{'order'} eq 'all') {
        return @result;
    }

    return undef;
}

=over 4

=item get_search_path ( $that, [ opt => val, ... ] )

    # To make include path for global site
    @path = @{tools::get_search_path('*')};
    # To make include path for a robot
    @path = @{tools::get_search_path($robot_id)};
    # To make include path for a family
    @path = @{tools::get_search_path($family)};
    # To make include path for a list
    @path = @{tools::get_search_path($list)};

make an array of include path for tt2 parsing

IN :
      -$that(+) : ref(List) | ref(Sympa::Family) | Robot | "*"
      -%options : options

Possible values for options:
    subdir    => directory ending each path
    lang      => language
    lang_only => if paths without lang subdirectory would be omitted

OUT : ref(ARRAY) of tt2 include path

=begin comment

Note:
As of 6.2b, argument $lang is recommended to be IETF language tag,
rather than locale name.

=end comment

=back

=cut

sub get_search_path {
    Log::do_log('debug3', '(%s, %s, %s)', @_);
    my $that    = shift;
    my %options = @_;

    my $subdir    = $options{'subdir'};
    my $lang      = $options{'lang'};
    my $lang_only = $options{'lang_only'};

    ## Get language subdirectories.
    my $lang_dirs;
    if ($lang) {
        ## For compatibility: add old-style "locale" directory at first.
        ## Add lang itself and fallback directories.
        $lang_dirs = [
            grep {$_} (
                Sympa::Language::lang2oldlocale($lang),
                Sympa::Language::implicated_langs($lang)
            )
        ];
    }

    return [_get_search_path($that, $subdir, $lang_dirs, $lang_only)];
}

sub _get_search_path {
    my $that = shift;
    my ($subdir, $lang_dirs, $lang_only) = @_;    # shift is not used

    my @search_path;

    if (ref $that and ref $that eq 'Sympa::List') {
        my $path_list;
        my $path_family;
        @search_path = _get_search_path($that->{'domain'}, @_);

        if ($subdir) {
            $path_list = $that->{'dir'} . '/' . $subdir;
        } else {
            $path_list = $that->{'dir'};
        }
        if ($lang_dirs) {
            unless ($lang_only) {
                unshift @search_path, $path_list;
            }
            unshift @search_path, map { $path_list . '/' . $_ } @$lang_dirs;
        } else {
            unshift @search_path, $path_list;
        }

        if (defined $that->get_family) {
            my $family = $that->get_family;
            if ($subdir) {
                $path_family = $family->{'dir'} . '/' . $subdir;
            } else {
                $path_family = $family->{'dir'};
            }
            if ($lang_dirs) {
                unless ($lang_only) {
                    unshift @search_path, $path_family;
                }
                unshift @search_path,
                    map { $path_family . '/' . $_ } @$lang_dirs;
            } else {
                unshift @search_path, $path_family;
            }
        }
    } elsif (ref $that and ref $that eq 'Sympa::Family') {
        my $path_family;
        @search_path = _get_search_path($that->{'robot'}, @_);

        if ($subdir) {
            $path_family = $that->{'dir'} . '/' . $subdir;
        } else {
            $path_family = $that->{'dir'};
        }
        if ($lang_dirs) {
            unless ($lang_only) {
                unshift @search_path, $path_family;
            }
            unshift @search_path, map { $path_family . '/' . $_ } @$lang_dirs;
        } else {
            unshift @search_path, $path_family;
        }
    } elsif (not ref $that and $that and $that ne '*') {    # Robot
        my $path_robot;
        @search_path = _get_search_path('*', @_);

        if ($that ne $Conf::Conf{'domain'}) {
            if ($subdir) {
                $path_robot =
                    $Conf::Conf{'etc'} . '/' . $that . '/' . $subdir;
            } else {
                $path_robot = $Conf::Conf{'etc'} . '/' . $that;
            }
            if ($lang_dirs) {
                unless ($lang_only) {
                    unshift @search_path, $path_robot;
                }
                unshift @search_path,
                    map { $path_robot . '/' . $_ } @$lang_dirs;
            } else {
                unshift @search_path, $path_robot;
            }
        }
    } elsif (not ref $that and $that eq '*') {    # Site
        my $path_etcbindir;
        my $path_etcdir;

        if ($subdir) {
            $path_etcbindir = Sympa::Constants::DEFAULTDIR . '/' . $subdir;
            $path_etcdir    = $Conf::Conf{'etc'} . '/' . $subdir;
        } else {
            $path_etcbindir = Sympa::Constants::DEFAULTDIR;
            $path_etcdir    = $Conf::Conf{'etc'};
        }
        if ($lang_dirs) {
            unless ($lang_only) {
                @search_path = (
                    (map { $path_etcdir . '/' . $_ } @$lang_dirs),
                    $path_etcdir,
                    (map { $path_etcbindir . '/' . $_ } @$lang_dirs),
                    $path_etcbindir
                );
            } else {
                @search_path = (
                    (map { $path_etcdir . '/' . $_ } @$lang_dirs),
                    (map { $path_etcbindir . '/' . $_ } @$lang_dirs)
                );
            }
        } else {
            @search_path = ($path_etcdir, $path_etcbindir);
        }
    } else {
        die 'bug in logic.  Ask developer';
    }

    return @search_path;
}

=over

=item send_file

    # To send site-global (not relative to a list or a robot)
    # message
    Site->send_file($template, $who, ...);
    # To send global (not relative to a list, but relative to a
    # robot) message
    $robot->send_file($template, $who, ...);
    # To send message relative to a list
    $list->send_file($template, $who, ...);

Send a message to user(s).
Find the tt2 file according to $tpl, set up
$data for the next parsing (with $context and
configuration)
Message is signed if the list has a key and a
certificate

Note: List::send_global_file() was deprecated.

=back

=cut

sub send_file {
    Log::do_log('debug2', '(%s, %s, %s, ...)', @_);
    my $that    = shift;
    my $tpl     = shift;
    my $who     = shift;
    my $context = shift || {};
    my %options = @_;

    my $message =
        Sympa::Message->new_from_template($that, $tpl, $who, $context,
        %options);
    # Use bulk excepted for alarms.  We should make this configurable in order
    # to support Sympa server on a machine without any MTA service.
    my $use_bulk = 1 unless $options{'alarm'};

    my $return_path;
    if (ref $that eq 'Sympa::List') {
        $return_path = $that->get_list_address('return_path');
    } else {
        $return_path = Conf::get_robot_conf($that || '*', 'request');
    }
    unless (
        $message
        and defined Sympa::Mail::sending(
            $message, $who, $return_path,
            #'priority' => Conf::get_robot_conf($robot_id, 'sympa_priority'),
            'use_bulk' => $use_bulk,
        )
        ) {
        Log::do_log('err', 'Could not send template %s to %s', $tpl, $who);
        return undef;
    }

    return 1;
}

# Sends a notice to listmaster by parsing
# listmaster_notification.tt2 template
#
# IN : -$operation (+): notification type
#      -$robot (+): robot
#      -$param(+) : ref(HASH) | ref(ARRAY)
#       values for template parsing
#
# OUT : 1 | undef
#

# Old name: List::send_notify_to_listmaster()
# Note: this would be moved to Site package.
sub send_notify_to_listmaster {
    Log::do_log('debug2', '(%s, %s, %s)', @_) unless $_[1] eq 'logs_failed';
    my $that      = shift;
    my $operation = shift;
    my $data      = shift;

    my ($list, $robot_id);
    if (ref $that eq 'Sympa::List') {
        $list     = $that;
        $robot_id = $list->{'domain'};
    } elsif ($that and $that ne '*') {
        $robot_id = $that;
    } else {
        $robot_id = '*';
    }

    my $listmaster =
        [split /\s*,\s*/, Conf::get_robot_conf($robot_id, 'listmaster')];
    my $to =
          Conf::get_robot_conf($robot_id, 'listmaster_email') . '@'
        . Conf::get_robot_conf($robot_id, 'host');

    if (ref $data ne 'HASH' and ref $data ne 'ARRAY') {
        die
            'Error on incoming parameter "$data", it must be a ref on HASH or a ref on ARRAY';
    }

    if (ref $data ne 'HASH') {
        my $d = {};
        foreach my $i ((0 .. $#{$data})) {
            $d->{"param$i"} = $data->[$i];
        }
        $data = $d;
    }

    $data->{'to'}             = $to;
    $data->{'type'}           = $operation;
    $data->{'auto_submitted'} = 'auto-generated';

    my @tosend;

    if ($operation eq 'no_db' or $operation eq 'db_restored') {
        $data->{'db_name'} = Conf::get_robot_conf($robot_id, 'db_name');
    }

    if ($operation eq 'loop_command') {
        ## Loop detected in Sympa
        $data->{'boundary'} =
            '----------=_' . tools::get_message_id($robot_id);
        tt2::allow_absolute_path();
    }

    if (   $operation eq 'request_list_creation'
        or $operation eq 'request_list_renaming') {
        foreach my $email (@$listmaster) {
            my $cdata = tools::dup_var($data);
            $cdata->{'one_time_ticket'} =
                Sympa::Auth::create_one_time_ticket($email, $robot_id,
                'get_pending_lists', $cdata->{'ip'});
            push @tosend,
                {
                email => $email,
                data  => $cdata
                };
        }
    } else {
        push @tosend,
            {
            email => $listmaster,
            data  => $data
            };
    }

    foreach my $ts (@tosend) {
        my $email = $ts->{'email'};
        # Skip DB access because DB is not accessible
        $email = [$email]
            if not ref $email
                and ($operation eq 'no_db' or $operation eq 'db_restored');

        my $notif_message =
            Sympa::Message->new_from_template($that,
            'listmaster_notification', $to, $ts->{'data'});
        $notif_message->{rcpt} = $email;

        unless ($notif_message
            and defined Sympa::Alarm::store($notif_message, $operation)) {
            Log::do_log(
                'notice',
                'Unable to send template "listmaster_notification" to %s listmaster %s',
                $robot_id,
                $listmaster
            ) unless $operation eq 'logs_failed';
            return undef;
        }
    }

    return 1;
}

## Find a file in an ordered list of directories
sub find_file {
    my ($filename, @directories) = @_;
    Log::do_log('debug3', '(%s, %s)', $filename, join(':', @directories));

    foreach my $d (@directories) {
        if (-f "$d/$filename") {
            return "$d/$filename";
        }
    }

    return undef;
}

## Recursively list the content of a directory
## Return an array of hash, each entry with directory + filename + encoding
sub list_dir {
    my $dir               = shift;
    my $all               = shift;
    my $original_encoding = shift; ## Suspected original encoding of filenames

    my $size = 0;

    if (opendir(DIR, $dir)) {
        foreach my $file (sort grep (!/^\.\.?$/, readdir(DIR))) {

            ## Guess filename encoding
            my ($encoding, $guess);
            my $decoder =
                Encode::Guess::guess_encoding($file, $original_encoding,
                'utf-8');
            if (ref $decoder) {
                $encoding = $decoder->name;
            } else {
                $guess = $decoder;
            }

            push @$all,
                {
                'directory' => $dir,
                'filename'  => $file,
                'encoding'  => $encoding,
                'guess'     => $guess
                };
            if (-d "$dir/$file") {
                list_dir($dir . '/' . $file, $all, $original_encoding);
            }
        }
        closedir DIR;
    }

    return 1;
}

## Q-encode a complete file hierarchy
## Usefull to Q-encode subshared documents
sub qencode_hierarchy {
    my $dir               = shift; ## Root directory
    my $original_encoding = shift; ## Suspected original encoding of filenames

    my $count;
    my @all_files;
    tools::list_dir($dir, \@all_files, $original_encoding);

    foreach my $f_struct (reverse @all_files) {

        ## At least one 8bit char
        next
            unless ($f_struct->{'filename'} =~ /[^\x00-\x7f]/);

        my $new_filename = $f_struct->{'filename'};
        my $encoding     = $f_struct->{'encoding'};
        Encode::from_to($new_filename, $encoding, 'utf8') if $encoding;

        ## Q-encode filename to escape chars with accents
        $new_filename = tools::qencode_filename($new_filename);

        my $orig_f = $f_struct->{'directory'} . '/' . $f_struct->{'filename'};
        my $new_f  = $f_struct->{'directory'} . '/' . $new_filename;

        ## Rename the file using utf8
        Log::do_log('notice', "Renaming %s to %s", $orig_f, $new_f);
        unless (rename $orig_f, $new_f) {
            Log::do_log('err', 'Failed to rename %s to %s: %m',
                $orig_f, $new_f);
            next;
        }
        $count++;
    }

    return $count;
}

## Dumps the value of each character of the inuput string
sub dump_encoding {
    my $out = shift;

    $out =~ s/./sprintf('%02x', ord($MATCH)).' '/eg;
    return $out;
}

## Remove PID file and STDERR output
sub remove_pid {
    my ($name, $pid, $options) = @_;

    my $piddir  = Sympa::Constants::PIDDIR;
    my $pidfile = $piddir . '/' . $name . '.pid';

    my @pids;

    # Lock pid file
    my $lock_fh = Sympa::LockedFile->new($pidfile, 5, '+<');
    unless ($lock_fh) {
        Log::do_log('err', 'Could not open %s to remove PID %s',
            $pidfile, $pid);
        return undef;
    }

    ## If in multi_process mode (bulk.pl for instance can have child
    ## processes) then the PID file contains a list of space-separated PIDs
    ## on a single line
    if ($options->{'multiple_process'}) {
        # Read pid file
        seek $lock_fh, 0, 0;
        my $l = <$lock_fh>;
        @pids = grep { /^[0-9]+$/ and $_ != $pid } split(/\s+/, $l);

        ## If no PID left, then remove the file
        unless (@pids) {
            ## Release the lock
            unless (unlink $pidfile) {
                Log::do_log('err', "Failed to remove %s: %m", $pidfile);
                $lock_fh->close;
                return undef;
            }
        } else {
            seek $lock_fh, 0, 0;
            truncate $lock_fh, 0;
            print $lock_fh join(' ', @pids) . "\n";
        }
    } else {
        unless (unlink $pidfile) {
            Log::do_log('err', "Failed to remove %s: %m", $pidfile);
            $lock_fh->close;
            return undef;
        }
        my $err_file = $Conf::Conf{'tmpdir'} . '/' . $pid . '.stderr';
        if (-f $err_file) {
            unless (unlink $err_file) {
                Log::do_log('err', "Failed to remove %s: %m", $err_file);
                $lock_fh->close;
                return undef;
            }
        }
    }

    $lock_fh->close;
    return 1;
}

# input user agent string and IP. return 1 if suspected to be a crawler.
# initial version based on rawlers_dtection.conf file only
# later : use Session table to identify those who create a lot of sessions
sub is_a_crawler {

    my $robot   = shift;
    my $context = shift;

#    if ($Conf::Conf{$robot}{'crawlers_detection'}) {
#	return ($Conf::Conf{$robot}{'crawlers_detection'}{'user_agent_string'}{$context->{'user_agent_string'}});
#    }

    # open (TMP, ">> /tmp/dump1"); print TMP "dump de la conf dans is_a_crawler : \n"; tools::dump_var($Conf::Conf{'crawlers_detection'}, 0,\*TMP);     close TMP;
    return $Conf::Conf{'crawlers_detection'}{'user_agent_string'}
        {$context->{'user_agent_string'}};
}

sub write_pid {
    my ($name, $pid, $options) = @_;

    my $piddir  = Sympa::Constants::PIDDIR;
    my $pidfile = $piddir . '/' . $name . '.pid';

    ## Create piddir
    mkdir($piddir, 0755) unless (-d $piddir);

    unless (
        tools::set_file_rights(
            file  => $piddir,
            user  => Sympa::Constants::USER,
            group => Sympa::Constants::GROUP,
        )
        ) {
        die sprintf 'Unable to set rights on %s. Exiting.', $piddir;
        ## No return
    }

    my @pids;

    # Lock pid file
    my $lock_fh = Sympa::LockedFile->new($pidfile, 5, '+>>');
    unless ($lock_fh) {
        die sprintf 'Unable to lock %s file in write mode. Exiting.',
            $pidfile;
    }
    ## If pidfile exists, read the PIDs
    if (-s $pidfile) {
        # Read pid file
        seek $lock_fh, 0, 0;
        my $l = <$lock_fh>;
        @pids = grep {/^[0-9]+$/} split(/\s+/, $l);
    }

    ## If we can have multiple instances for the process.
    ## Print other pids + this one
    if ($options->{'multiple_process'}) {
        ## Print other pids + this one
        push(@pids, $pid);

        seek $lock_fh, 0, 0;
        truncate $lock_fh, 0;
        print $lock_fh join(' ', @pids) . "\n";
    } else {
        ## The previous process died suddenly, without pidfile cleanup
        ## Send a notice to listmaster with STDERR of the previous process
        if (@pids) {
            my $other_pid = $pids[0];
            Log::do_log('notice',
                'Previous process %s died suddenly; notifying listmaster',
                $other_pid);
            my $pname = $0;
            $pname =~ s/.*\/(\w+)/$1/;
            send_crash_report(('pid' => $other_pid, 'pname' => $pname));
        }

        seek $lock_fh, 0, 0;
        unless (truncate $lock_fh, 0) {
            ## Unlock pid file
            $lock_fh->close();
            die sprintf 'Could not truncate %s, exiting.', $pidfile;
        }

        print $lock_fh $pid . "\n";
    }

    unless (
        tools::set_file_rights(
            file  => $pidfile,
            user  => Sympa::Constants::USER,
            group => Sympa::Constants::GROUP,
        )
        ) {
        ## Unlock pid file
        $lock_fh->close();
        die sprintf 'Unable to set rights on %s', $pidfile;
    }
    ## Unlock pid file
    $lock_fh->close();

    return 1;
}

sub direct_stderr_to_file {
    my %data = @_;
    ## Error output is stored in a file with PID-based name
    ## Usefull if process crashes
    open(STDERR, '>>',
        $Conf::Conf{'tmpdir'} . '/' . $data{'pid'} . '.stderr');
    unless (
        tools::set_file_rights(
            file  => $Conf::Conf{'tmpdir'} . '/' . $data{'pid'} . '.stderr',
            user  => Sympa::Constants::USER,
            group => Sympa::Constants::GROUP,
        )
        ) {
        Log::do_log(
            'err',
            'Unable to set rights on %s',
            $Conf::Conf{'tmpdir'} . '/' . $data{'pid'} . '.stderr'
        );
        return undef;
    }
    return 1;
}

# Send content of $pid.stderr to listmaster for process whose pid is $pid.
sub send_crash_report {
    my %data = @_;
    Log::do_log('debug', 'Sending crash report for process %s', $data{'pid'}),
        my $err_file = $Conf::Conf{'tmpdir'} . '/' . $data{'pid'} . '.stderr';

    my $language = Sympa::Language->instance;
    my (@err_output, $err_date);
    if (-f $err_file) {
        open(ERR, $err_file);
        @err_output = map { chomp $_; $_; } <ERR>;
        close ERR;

        my $err_date_epoch = (stat $err_file)[9];
        if (defined $err_date_epoch) {
            $err_date = $language->gettext_strftime("%d %b %Y  %H:%M",
                localtime $err_date_epoch);
        } else {
            $err_date = $language->gettext('(unknown date)');
        }
    } else {
        $err_date = $language->gettext('(unknown date)');
    }
    tools::send_notify_to_listmaster(
        '*', 'crash',
        {   'crashed_process' => $data{'pname'},
            'crash_err'       => \@err_output,
            'crash_date'      => $err_date,
            'pid'             => $data{'pid'}
        }
    );
}

sub get_message_id {
    my $robot = shift;

    my $domain;
    if ($robot and $robot ne '*') {
        $domain = Conf::get_robot_conf($robot, 'domain');
    } else {
        $domain = $Conf::Conf{'domain'};
    }

    return sprintf '<sympa.%d.%d.%d@%s>', time, $PID, int(rand(999)), $domain;
}

sub get_dir_size {
    my $dir = shift;

    my $size = 0;

    if (opendir(DIR, $dir)) {
        foreach my $file (sort grep (!/^\./, readdir(DIR))) {
            if (-d "$dir/$file") {
                $size += get_dir_size("$dir/$file");
            } else {
                my @info = stat "$dir/$file";
                $size += $info[7];
            }
        }
        closedir DIR;
    }

    return $size;
}

## Basic check of an email address
sub valid_email {
    my $email = shift;

    my $email_re = Sympa::Regexps::email();
    unless ($email =~ /^${email_re}$/) {
        Log::do_log('err', 'Invalid email address "%s"', $email);
        return undef;
    }

    ## Forbidden characters
    if ($email =~ /[\|\$\*\?\!]/) {
        Log::do_log('err', 'Invalid email address "%s"', $email);
        return undef;
    }

    return 1;
}

## Clean email address
sub clean_email {
    my $email = shift;

    ## Lower-case
    $email = lc($email);

    ## remove leading and trailing spaces
    $email =~ s/^\s*//;
    $email =~ s/\s*$//;

    return $email;
}

## Return canonical email address (lower-cased + space cleanup)
## It could also support alternate email
sub get_canonical_email {
    my $email = shift;

    ## Remove leading and trailing white spaces
    $email =~ s/^\s*(\S.*\S)\s*$/$1/;

    ## Lower-case
    $email = lc($email);

    return $email;
}

## Function for Removing a non-empty directory
## It takes a variale number of arguments :
## it can be a list of directory
## or few direcoty paths
sub remove_dir {

    Log::do_log('debug2', '');

    foreach my $current_dir (@_) {
        finddepth({wanted => \&del, no_chdir => 1}, $current_dir);
    }

    sub del {
        my $name = $File::Find::name;

        if (!-l && -d _) {
            unless (rmdir($name)) {
                Log::do_log('err', 'Error while removing dir %s', $name);
            }
        } else {
            unless (unlink($name)) {
                Log::do_log('err', 'Error while removing file %s', $name);
            }
        }
    }
    return 1;
}

## Dump a variable's content
sub dump_var {
    my ($var, $level, $fd) = @_;

    return undef unless ($fd);

    if (ref($var)) {
        if (ref($var) eq 'ARRAY') {
            foreach my $index (0 .. $#{$var}) {
                print $fd "\t" x $level . $index . "\n";
                dump_var($var->[$index], $level + 1, $fd);
            }
        } elsif (ref($var) eq 'HASH'
            || ref($var) eq 'Sympa::Scenario'
            || ref($var) eq 'Sympa::List'
            || ref($var) eq 'CGI::Fast') {
            foreach my $key (sort keys %{$var}) {
                print $fd "\t" x $level . '_' . $key . '_' . "\n";
                dump_var($var->{$key}, $level + 1, $fd);
            }
        } else {
            printf $fd "\t" x $level . "'%s'" . "\n", ref($var);
        }
    } else {
        if (defined $var) {
            print $fd "\t" x $level . "'$var'" . "\n";
        } else {
            print $fd "\t" x $level . "UNDEF\n";
        }
    }
}

## Dump a variable's content
sub dump_html_var {
    my ($var) = shift;
    my $html = '';

    if (ref($var)) {

        if (ref($var) eq 'ARRAY') {
            $html .= '<ul>';
            foreach my $index (0 .. $#{$var}) {
                $html .= '<li> ' . $index . ':';
                $html .= dump_html_var($var->[$index]);
                $html .= '</li>';
            }
            $html .= '</ul>';
        } elsif (ref($var) eq 'HASH'
            || ref($var) eq 'Sympa::Scenario'
            || ref($var) eq 'Sympa::List') {
            $html .= '<ul>';
            foreach my $key (sort keys %{$var}) {
                $html .= '<li>' . $key . '=';
                $html .= dump_html_var($var->{$key});
                $html .= '</li>';
            }
            $html .= '</ul>';
        } else {
            $html .= 'EEEEEEEEEEEEEEEEEEEEE' . ref($var);
        }
    } else {
        if (defined $var) {
            $html .= escape_html($var);
        } else {
            $html .= 'UNDEF';
        }
    }
    return $html;
}

## Dump a variable's content
sub dump_html_var2 {
    my ($var) = shift;

    my $html = '';

    if (ref($var)) {
        if (ref($var) eq 'ARRAY') {
            $html .= 'ARRAY <ul>';
            foreach my $index (0 .. $#{$var}) {
                $html .= '<li> ' . $index;
                $html .= dump_html_var($var->[$index]);
                $html .= '</li>';
            }
            $html .= '</ul>';
        } elsif (ref($var) eq 'HASH'
            || ref($var) eq 'Sympa::Scenario'
            || ref($var) eq 'Sympa::List') {
            #$html .= " (".ref($var).') <ul>';
            $html .= '<ul>';
            foreach my $key (sort keys %{$var}) {
                $html .= '<li>' . $key . '=';
                $html .= dump_html_var($var->{$key});
                $html .= '</li>';
            }
            $html .= '</ul>';
        } else {
            $html .= sprintf "<li>'%s'</li>", ref($var);
        }
    } else {
        if (defined $var) {
            $html .= '<li>' . $var . '</li>';
        } else {
            $html .= '<li>UNDEF</li>';
        }
    }
    return $html;
}

sub remove_empty_entries {
    my ($var) = @_;
    my $not_empty = 0;

    if (ref($var)) {
        if (ref($var) eq 'ARRAY') {
            foreach my $index (0 .. $#{$var}) {
                my $status = remove_empty_entries($var->[$index]);
                $var->[$index] = undef unless ($status);
                $not_empty ||= $status;
            }
        } elsif (ref($var) eq 'HASH') {
            foreach my $key (sort keys %{$var}) {
                my $status = remove_empty_entries($var->{$key});
                $var->{$key} = undef unless ($status);
                $not_empty ||= $status;
            }
        }
    } else {
        if (defined $var && $var) {
            $not_empty = 1;
        }
    }

    return $not_empty;
}

## Duplictate a complex variable
sub dup_var {
    my ($var) = @_;

    if (ref($var)) {
        if (ref($var) eq 'ARRAY') {
            my $new_var = [];
            foreach my $index (0 .. $#{$var}) {
                $new_var->[$index] = dup_var($var->[$index]);
            }
            return $new_var;
        } elsif (ref($var) eq 'HASH') {
            my $new_var = {};
            foreach my $key (sort keys %{$var}) {
                $new_var->{$key} = dup_var($var->{$key});
            }
            return $new_var;
        }
    }

    return $var;
}

####################################################
# get_array_from_splitted_string
####################################################
# return an array made on a string splited by ','.
# It removes spaces.
#
#
# IN : -$string (+): string to split
#
# OUT : -ref(ARRAY)
#
######################################################
sub get_array_from_splitted_string {
    my ($string) = @_;
    my @array;

    foreach my $word (split /,/, $string) {
        $word =~ s/^\s+//;
        $word =~ s/\s+$//;
        push @array, $word;
    }

    return \@array;
}

####################################################
# diff_on_arrays
####################################################
# Makes set operation on arrays (seen as set, with no double) :
#  - deleted : A \ B
#  - added : B \ A
#  - intersection : A /\ B
#  - union : A \/ B
#
# IN : -$setA : ref(ARRAY) - set
#      -$setB : ref(ARRAY) - set
#
# OUT : -ref(HASH) with keys :
#          deleted, added, intersection, union
#
#######################################################
sub diff_on_arrays {
    my ($setA, $setB) = @_;
    my $result = {
        'intersection' => [],
        'union'        => [],
        'added'        => [],
        'deleted'      => []
    };
    my %deleted;
    my %added;
    my %intersection;
    my %union;

    my %hashA;
    my %hashB;

    foreach my $eltA (@$setA) {
        $hashA{$eltA}   = 1;
        $deleted{$eltA} = 1;
        $union{$eltA}   = 1;
    }

    foreach my $eltB (@$setB) {
        $hashB{$eltB} = 1;
        $added{$eltB} = 1;

        if ($hashA{$eltB}) {
            $intersection{$eltB} = 1;
            $deleted{$eltB}      = 0;
        } else {
            $union{$eltB} = 1;
        }
    }

    foreach my $eltA (@$setA) {
        if ($hashB{$eltA}) {
            $added{$eltA} = 0;
        }
    }

    foreach my $elt (keys %deleted) {
        next unless $elt;
        push @{$result->{'deleted'}}, $elt if ($deleted{$elt});
    }
    foreach my $elt (keys %added) {
        next unless $elt;
        push @{$result->{'added'}}, $elt if ($added{$elt});
    }
    foreach my $elt (keys %intersection) {
        next unless $elt;
        push @{$result->{'intersection'}}, $elt if ($intersection{$elt});
    }
    foreach my $elt (keys %union) {
        next unless $elt;
        push @{$result->{'union'}}, $elt if ($union{$elt});
    }

    return $result;

}

####################################################
# is_in_array
####################################################
# Test if a value is on an array
#
# IN : -$setA : ref(ARRAY) - set
#      -$value : a serached value
#
# OUT : boolean
#######################################################
sub is_in_array {
    my $set = shift;
    die 'missing parameter "$value"' unless @_;
    my $value = shift;

    if (defined $value) {
        foreach my $elt (@{$set || []}) {
            next unless defined $elt;
            return 1 if $elt eq $value;
        }
    } else {
        foreach my $elt (@{$set || []}) {
            return 1 unless defined $elt;
        }
    }

    return undef;
}

####################################################
# a_is_older_than_b
####################################################
# Compares the last modifications date of two files
#
# IN : - a hash with two entries:
#
#        * a_file : the full path to a file
#        * b_file : the full path to a file
#
# OUT : 1 if the last modification date of "a_file" is older than
# "b_file"'s, 0 otherwise.
#       return undef if the comparison could not be carried on.
#######################################################
sub a_is_older_than_b {
    my $param = shift;

    return undef unless -r $param->{'a_file'} and -r $param->{'b_file'};
    return (tools::get_mtime($param->{'a_file'}) <
            tools::get_mtime($param->{'b_file'})) ? 1 : 0;
}

=over

=item smart_eq ( $a, $b )

I<Function>.
Check if two strings are identical.

Parameters:

=over

=item $a, $b

Operands.

If both of them are undefined, they are equal.
If only one of them is undefined, the are not equal.
If C<$b> is a L<Regexp> object and it matches to C<$a>, they are equal.
Otherwise, they are compared as strings.

=back

Returns:

If arguments matched, true value.  Otherwise false value.

=back

=cut

sub smart_eq {
    die 'missing argument' if scalar @_ < 2;
    my ($a, $b) = @_;

    if (defined $a and defined $b) {
        if (ref $b eq 'Regexp') {
            return 1 if $a =~ $b;
        } else {
            return 1 if $a eq $b;
        }
    } elsif (!defined $a and !defined $b) {
        return 1;
    }

    return undef;
}

####################################################
# clean_msg_id
####################################################
# clean msg_id to use it without  \n, \s or <,>
#
# IN : -$msg_id (+) : the msg_id
#
# OUT : -$msg_id : the clean msg_id
#
######################################################
sub clean_msg_id {
    my $msg_id = shift;

    return $msg_id unless defined $msg_id;

    chomp $msg_id;

    if ($msg_id =~ /\<(.+)\>/) {
        $msg_id = $1;
    }

    return $msg_id;
}

#XXX NOT USED
## Change X-Sympa-To: header field in the message
sub change_x_sympa_to {
    my ($file, $value) = @_;

    ## Change X-Sympa-To
    unless (open FILE, $file) {
        Log::do_log('err', 'Unable to open "%s": %m', $file);
        next;
    }
    my @content = <FILE>;
    close FILE;

    unless (open FILE, ">$file") {
        Log::do_log('err', 'Unable to open "%s": %m', "$file");
        next;
    }
    foreach (@content) {
        if (/^X-Sympa-To:/i) {
            $_ = "X-Sympa-To: $value\n";
        }
        print FILE;
    }
    close FILE;

    return 1;
}

## Compare 2 versions of Sympa
sub higher_version {
    my ($v1, $v2) = @_;

    my @tab1 = split /\./, $v1;
    my @tab2 = split /\./, $v2;

    my $max = $#tab1;
    $max = $#tab2 if ($#tab2 > $#tab1);

    for my $i (0 .. $max) {

        if ($tab1[0] =~ /^(\d*)a$/) {
            $tab1[0] = $1 - 0.5;
        } elsif ($tab1[0] =~ /^(\d*)b$/) {
            $tab1[0] = $1 - 0.25;
        }

        if ($tab2[0] =~ /^(\d*)a$/) {
            $tab2[0] = $1 - 0.5;
        } elsif ($tab2[0] =~ /^(\d*)b$/) {
            $tab2[0] = $1 - 0.25;
        }

        if ($tab1[0] eq $tab2[0]) {
            #printf "\t%s = %s\n",$tab1[0],$tab2[0];
            shift @tab1;
            shift @tab2;
            next;
        }
        return ($tab1[0] > $tab2[0]);
    }

    return 0;
}

## Compare 2 versions of Sympa
sub lower_version {
    my ($v1, $v2) = @_;

    my @tab1 = split /\./, $v1;
    my @tab2 = split /\./, $v2;

    my $max = $#tab1;
    $max = $#tab2 if ($#tab2 > $#tab1);

    for my $i (0 .. $max) {

        if ($tab1[0] =~ /^(\d*)a$/) {
            $tab1[0] = $1 - 0.5;
        } elsif ($tab1[0] =~ /^(\d*)b$/) {
            $tab1[0] = $1 - 0.25;
        }

        if ($tab2[0] =~ /^(\d*)a$/) {
            $tab2[0] = $1 - 0.5;
        } elsif ($tab2[0] =~ /^(\d*)b$/) {
            $tab2[0] = $1 - 0.25;
        }

        if ($tab1[0] eq $tab2[0]) {
            #printf "\t%s = %s\n",$tab1[0],$tab2[0];
            shift @tab1;
            shift @tab2;
            next;
        }
        return ($tab1[0] < $tab2[0]);
    }

    return 0;
}

sub add_in_blacklist {
    my $entry = shift;
    my $robot = shift;
    my $list  = shift;

    Log::do_log('info', '(%s, %s, %s)', $entry, $robot, $list->{'name'});
    $entry = lc($entry);
    chomp $entry;

    # robot blacklist not yet availible
    unless ($list) {
        Log::do_log('info',
            "tools::add_in_blacklist: robot blacklist not yet availible, missing list parameter"
        );
        return undef;
    }
    unless (($entry) && ($robot)) {
        Log::do_log('info', 'Missing parameters');
        return undef;
    }
    if ($entry =~ /\*.*\*/) {
        Log::do_log('info', 'Incorrect parameter %s', $entry);
        return undef;
    }
    my $dir = $list->{'dir'} . '/search_filters';
    unless ((-d $dir) || mkdir($dir, 0755)) {
        Log::do_log('info', 'Unable to create dir %s', $dir);
        return undef;
    }
    my $file = $dir . '/blacklist.txt';

    if (open BLACKLIST, "$file") {
        while (<BLACKLIST>) {
            next if (/^\s*$/o || /^[\#\;]/o);
            my $regexp = $_;
            chomp $regexp;
            $regexp =~ s/\*/.*/;
            $regexp = '^' . $regexp . '$';
            if ($entry =~ /$regexp/i) {
                Log::do_log('notice', '%s already in blacklist(%s)',
                    $entry, $_);
                return 0;
            }
        }
        close BLACKLIST;
    }
    unless (open BLACKLIST, ">> $file") {
        Log::do_log('info', 'Append to file %s', $file);
        return undef;
    }
    print BLACKLIST "$entry\n";
    close BLACKLIST;

}

############################################################
#  get_fingerprint                                         #
############################################################
#  Used in 2 cases :                                       #
#  - check the md5 in the url                              #
#  - create an md5 to put in a url                         #
#                                                          #
#  Use : get_db_random()                                   #
#        init_db_random()                                  #
#        md5_fingerprint()                                 #
#                                                          #
# IN : $email : email of the subscriber                    #
#      $fingerprint : the fingerprint in the url (1st case)#
#                                                          #
# OUT : $fingerprint : a md5 for create an url             #
#     | 1 : if the md5 in the url is true                  #
#     | undef                                              #
#                                                          #
############################################################
sub get_fingerprint {

    my $email       = shift;
    my $fingerprint = shift;
    my $random;
    my $random_email;

    unless ($random = get_db_random()) { # si un random existe : get_db_random
        $random = init_db_random();      # sinon init_db_random
    }

    $random_email = ($random . $email);

    if ($fingerprint) {    #si on veut vérifier le fingerprint dans l'url

        if ($fingerprint eq md5_fingerprint($random_email)) {
            return 1;
        } else {
            return undef;
        }

    } else { #si on veut créer une url de type http://.../sympa/unsub/$list/$email/get_fingerprint($email)

        $fingerprint = md5_fingerprint($random_email);
        return $fingerprint;

    }
}

############################################################
#  md5_fingerprint                                         #
############################################################
#  The algorithm MD5 (Message Digest 5) is a cryptographic #
#  hash function which permit to obtain                    #
#  the fingerprint of a file/data                          #
#                                                          #
# IN : a string                                            #
#                                                          #
# OUT : md5 digest                                         #
#     | undef                                              #
#                                                          #
############################################################
sub md5_fingerprint {

    my $input_string = shift;
    return undef unless (defined $input_string);
    chomp $input_string;

    my $digestmd5 = Digest::MD5->new;
    $digestmd5->reset;
    $digestmd5->add($input_string);
    return (unpack("H*", $digestmd5->digest));
}

############################################################
#  get_db_random                                           #
############################################################
#  This function returns $random                           #
#  which is stored in the database                         #
#                                                          #
# IN : -                                                   #
#                                                          #
# OUT : $random : the random stored in the database        #
#     | undef                                              #
#                                                          #
############################################################
sub get_db_random {

    my $sth;
    unless ($sth = SDM::do_query("SELECT random FROM fingerprint_table")) {
        Log::do_log('err',
            'Unable to retrieve random value from fingerprint_table');
        return undef;
    }
    my $random = $sth->fetchrow_hashref('NAME_lc');

    return $random;

}

############################################################
#  init_db_random                                          #
############################################################
#  This function initializes $random used in               #
#  get_fingerprint if there is no value in the database    #
#                                                          #
# IN : -                                                   #
#                                                          #
# OUT : $random : the random initialized in the database   #
#     | undef                                              #
#                                                          #
############################################################
sub init_db_random {

    my $range   = 89999999999999999999;
    my $minimum = 10000000000000000000;

    my $random = int(rand($range)) + $minimum;

    unless (
        SDM::do_query('INSERT INTO fingerprint_table VALUES (%d)', $random)) {
        Log::do_log('err', 'Unable to set random value in fingerprint_table');
        return undef;
    }
    return $random;
}

sub get_separator {
    return $separator;
}

## Return the Sympa regexp corresponding to the input param
# OBSOLETED: Use Sympa::Regexps::<type>().
sub get_regexp {
    my $type = shift;

    if (my $re = Sympa::Regexps->can($type)) {
        return $re->();
    } else {
        return '\w+';    ## default is a very strict regexp
    }

}

## convert a string formated as var1="value1";var2="value2"; into a hash.
## Used when extracting from session table some session properties or when
## extracting users preference from user table
## Current encoding is NOT compatible with encoding of values with '"'
##
sub string_2_hash {
    my $data = shift;
    my %hash;

    pos($data) = 0;
    while ($data =~ /\G;?(\w+)\=\"((\\[\"\\]|[^\"])*)\"(?=(;|\z))/g) {
        my ($var, $val) = ($1, $2);
        $val =~ s/\\([\"\\])/$1/g;
        $hash{$var} = $val;
    }

    return (%hash);

}
## convert a hash into a string formated as var1="value1";var2="value2"; into
## a hash
sub hash_2_string {
    my $refhash = shift;

    return undef unless ref $refhash eq 'HASH';

    my $data_string;
    foreach my $var (keys %$refhash) {
        next unless length $var;
        my $val = $refhash->{$var};
        $val = '' unless defined $val;

        $val =~ s/([\"\\])/\\$1/g;
        $data_string .= ';' . $var . '="' . $val . '"';
    }
    return ($data_string);
}

=pod 

=head2 sub save_to_bad(HASH $param)

Saves a message file to the "bad/" spool of a given queue. Creates this directory if not found.

=head3 Arguments 

=over 

=item * I<param> : a hash containing all the arguments, which means:

=over 4

=item * I<file> : the characters string of the path to the file to copy to bad;

=item * I<hostname> : the characters string of the name of the virtual host concerned;

=item * I<queue> : the characters string of the name of the queue.

=back

=back 

=head3 Return 

=over

=item * 1 if the file was correctly saved to the "bad/" directory;

=item * undef if something went wrong.

=back 

=head3 Calls 

=over 

=item * tools::send_notify_to_listmaster

=back 

=cut 

sub save_to_bad {

    my $param = shift;

    my $file     = $param->{'file'};
    my $robot_id = $param->{'hostname'};
    my $queue    = $param->{'queue'};

    if (!-d $queue . '/bad') {
        unless (mkdir $queue . '/bad', 0775) {
            Log::do_log('notice', 'Unable to create %s/bad/ directory',
                $queue);
            tools::send_notify_to_listmaster($robot_id,
                'unable_to_create_dir', {'dir' => "$queue/bad"});
            return undef;
        }
        Log::do_log('debug', 'mkdir %s/bad', $queue);
    }
    Log::do_log(
        'notice',
        "Saving file %s to %s",
        $queue . '/' . $file,
        $queue . '/bad/' . $file
    );
    unless (rename($queue . '/' . $file, $queue . '/bad/' . $file)) {
        Log::do_log(
            'notice',
            'Could not rename %s to %s: %m',
            $queue . '/' . $file,
            $queue . '/bad/' . $file
        );
        return undef;
    }

    return 1;
}

=pod 

=head2 sub CleanSpool(STRING $spool_dir, INT $clean_delay)

Clean all messages in spool $spool_dir older than $clean_delay.

=head3 Arguments 

=over 

=item * I<spool_dir> : a string corresponding to the path to the spool to clean;

=item * I<clean_delay> : the delay between the moment we try to clean spool and the last modification date of a file.

=back

=back 

=head3 Return 

=over

=item * 1 if the spool was cleaned withou troubles.

=item * undef if something went wrong.

=back 

=head3 Calls 

=over 

=item * tools::remove_dir

=back 

=cut 

############################################################
#  CleanSpool
############################################################
#  Cleans files older than $clean_delay from spool $spool_dir
#
# IN : -$spool_dir (+): the spool directory
#      -$clean_delay (+): delay in days
#
# OUT : 1
#
##############################################################
sub CleanSpool {
    my ($spool_dir, $clean_delay) = @_;
    Log::do_log('debug', '(%s, %s)', $spool_dir, $clean_delay);

    unless (opendir(DIR, $spool_dir)) {
        Log::do_log('err', 'Unable to open "%s" spool: %m', $spool_dir);
        return undef;
    }

    my @qfile = sort grep (!/^\.+$/, readdir(DIR));
    closedir DIR;

    my ($curlist, $moddelay);
    foreach my $f (@qfile) {
        if (tools::get_mtime("$spool_dir/$f") <
            time - $clean_delay * 60 * 60 * 24) {
            if (-f "$spool_dir/$f") {
                unlink("$spool_dir/$f");
                Log::do_log('notice', 'Deleting old file %s',
                    "$spool_dir/$f");
            } elsif (-d "$spool_dir/$f") {
                unless (tools::remove_dir("$spool_dir/$f")) {
                    Log::do_log('err', 'Cannot remove old directory %s: %m',
                        "$spool_dir/$f");
                    next;
                }
                Log::do_log('notice', 'Deleting old directory %s',
                    "$spool_dir/$f");
            }
        }
    }

    return 1;
}

# return a lockname that is a uniq id of a processus (hostname + pid) ;
# hostname(20) and pid(10) are truncated in order to store lockname in
# database varchar(30)
sub get_lockname {
    return substr(substr(Sys::Hostname::hostname(), 0, 20) . $PID, 0, 30);
}

## compare 2 scalars, string/numeric independant
sub smart_lessthan {
    my ($stra, $strb) = @_;
    $stra =~ s/^\s+//;
    $stra =~ s/\s+$//;
    $strb =~ s/^\s+//;
    $strb =~ s/\s+$//;
    $ERRNO = 0;
    my ($numa, $unparsed) = POSIX::strtod($stra);
    my $numb;
    $numb = POSIX::strtod($strb)
        unless ($ERRNO || $unparsed != 0);

    if (($stra eq '') || ($strb eq '') || ($unparsed != 0) || $ERRNO) {
        return $stra lt $strb;
    } else {
        return $stra < $strb;
    }
}

## Returns the list of pid identifiers in the pid file.
sub get_pids_in_pid_file {
    my $name = shift;

    my $piddir  = Sympa::Constants::PIDDIR;
    my $pidfile = $piddir . '/' . $name . '.pid';

    my $lock_fh = Sympa::LockedFile->new($pidfile, 5, '<');
    unless ($lock_fh) {
        Log::do_log('err', 'Unable to open PID file %s: %m', $pidfile);
        return undef;
    }
    my $l = <$lock_fh>;
    my @pids = grep {/^[0-9]+$/} split(/\s+/, $l);
    $lock_fh->close;
    return \@pids;
}

## Returns the counf of numbers found in the string given as argument.
sub count_numbers_in_string {
    my $str   = shift;
    my $count = 0;
    $count++ while $str =~ /(\d+\s+)/g;
    return $count;
}

#*******************************************
# Function : wrap_text
# Description : return line-wrapped text.
## IN : text, init, subs, cols
#*******************************************
sub wrap_text {
    my $text = shift;
    my $init = shift;
    my $subs = shift;
    my $cols = shift;
    $cols = 78 unless defined $cols;
    return $text unless $cols;

    $text = Text::LineFold->new(
        Language      => Sympa::Language->instance->get_lang,
        OutputCharset => (Encode::is_utf8($text) ? '_UNICODE_' : 'utf8'),
        Prep          => 'NONBREAKURI',
        ColumnsMax    => $cols
    )->fold($init, $subs, $text);

    return $text;
}

#*******************************************
# Function : addrencode
# Description : return formatted (and encoded) name-addr as RFC5322 3.4.
## IN : addr, [phrase, [charset, [comment]]]
#*******************************************
sub addrencode {
    my $addr    = shift;
    my $phrase  = (shift || '');
    my $charset = (shift || 'utf8');
    my $comment = (shift || '');

    return undef unless $addr =~ /\S/;

    if ($phrase =~ /[^\s\x21-\x7E]/) {
        $phrase = MIME::EncWords::encode_mimewords(
            Encode::decode('utf8', $phrase),
            'Encoding'    => 'A',
            'Charset'     => $charset,
            'Replacement' => 'FALLBACK',
            'Field'       => 'Resent-Sender', # almost longest
            'Minimal'     => 'DISPNAME',      # needs MIME::EncWords >= 1.012.
        );
    } elsif ($phrase =~ /\S/) {
        $phrase =~ s/([\\\"])/\\$1/g;
        $phrase = '"' . $phrase . '"';
    }
    if ($comment =~ /[^\s\x21-\x27\x2A-\x5B\x5D-\x7E]/) {
        $comment = MIME::EncWords::encode_mimewords(
            Encode::decode('utf8', $comment),
            'Encoding'    => 'A',
            'Charset'     => $charset,
            'Replacement' => 'FALLBACK',
            'Minimal'     => 'DISPNAME',
        );
    } elsif ($comment =~ /\S/) {
        $comment =~ s/([\\\"])/\\$1/g;
    }

    return
          ($phrase  =~ /\S/ ? "$phrase "    : '')
        . ($comment =~ /\S/ ? "($comment) " : '')
        . "<$addr>";
}

# Generate a newsletter from an HTML URL or a file path.
#sub create_html_part_from_web_page($param);
#DEPRECATED: No longer used.

sub get_children_processes_list {
    Log::do_log('debug3', '');
    my @children;
    for my $p (@{Proc::ProcessTable->new->table}) {
        if ($p->ppid == $PID) {
            push @children, $p->pid;
        }
    }
    return @children;
}

#*******************************************
# Function : decode_header
# Description : return header value decoded to UTF-8 or undef.
#               trailing newline will be removed.
#               If sep is given, return all occurrences joined by it.
## IN : msg, tag, [sep]
#*******************************************
sub decode_header {
    my $msg = shift;
    my $tag = shift;
    my $sep = shift || undef;

    my $head;
    if (ref $msg eq 'Sympa::Message') {
        $head = $msg->head;
    } elsif (ref $msg eq 'MIME::Entity') {
        $head = $msg->head;
    } elsif (ref $msg eq 'MIME::Head' or ref $msg eq 'Mail::Header') {
        $head = $msg;
    }
    if (defined $sep) {
        my @values = $head->get($tag);
        return undef unless scalar @values;
        foreach my $val (@values) {
            $val = MIME::EncWords::decode_mimewords($val, Charset => 'UTF-8');
            chomp $val;
        }
        return join $sep, @values;
    } else {
        my $val = $head->get($tag);
        return undef unless defined $val;
        $val = MIME::EncWords::decode_mimewords($val, Charset => 'UTF-8');
        chomp $val;
        return $val;
    }
}

BEGIN { 'use Data::Password'; }

my @validation_messages = (
    {gettext_id => 'Not between %d and %d characters'},
    {gettext_id => 'Not %d characters or greater'},
    {gettext_id => 'Not less than or equal to %d characters'},
    {gettext_id => 'contains bad characters'},
    {gettext_id => 'contains less than %d character groups'},
    {gettext_id => 'contains over %d leading characters in sequence'},
    {gettext_id => "contains the dictionary word '%s'"},
);

sub password_validation {
    my ($password) = @_;

    my $pv = $Conf::Conf{'password_validation'};
    return undef
        unless $pv
            and defined $password
            and $Data::Password::VERSION;

    local (
        $Data::Password::DICTIONARY, $Data::Password::FOLLOWING,
        $Data::Password::GROUPS,     $Data::Password::MINLEN,
        $Data::Password::MAXLEN
    );
    local @Data::Password::DICTIONARIES = @Data::Password::DICTIONARIES;

    my @techniques = split(/\s*,\s*/, $pv);
    foreach my $technique (@techniques) {
        my ($key, $value) = $technique =~ /([^=]+)=(.*)/;
        $key = uc $key;

        if ($key eq 'DICTIONARY') {
            $Data::Password::DICTIONARY = $value;
        } elsif ($key eq 'FOLLOWING') {
            $Data::Password::FOLLOWING = $value;
        } elsif ($key eq 'GROUPS') {
            $Data::Password::GROUPS = $value;
        } elsif ($key eq 'MINLEN') {
            $Data::Password::MINLEN = $value;
        } elsif ($key eq 'MAXLEN') {
            $Data::Password::MAXLEN = $value;
        } elsif ($key eq 'DICTIONARIES') {
            # TODO: How do we handle a list of dictionaries?
            push @Data::Password::DICTIONARIES, $value;
        }
    }
    my $output = Data::Password::IsBadPassword($password);
    return undef unless $output;

    # Translate result if possible.
    my $language = Sympa::Language->instance;
    foreach my $item (@validation_messages) {
        my $format = $item->{'gettext_id'};
        my $regexp = quotemeta $format;
        $regexp =~ s/\\\%[sd]/(.+)/g;

        my ($match, @args) = ($output =~ /($regexp)/i);
        next unless $match;
        return $language->gettext_sprintf($format, @args);
    }
    return $output;
}

#*******************************************
## Function : foldcase
## Description : returns "fold-case" string suitable for case-insensitive
## match.
### IN : str
##*******************************************
sub foldcase {
    my $str = shift;
    return '' unless defined $str and length $str;

    if ($] <= 5.008) {
        # Perl 5.8.0 does not support Unicode::CaseFold. Use lc() instead.
        return Encode::encode_utf8(lc(Encode::decode_utf8($str)));
    } else {
        # later supports it. Perl 5.16.0 and later have built-in fc().
        return Encode::encode_utf8(fc(Encode::decode_utf8($str)));
    }
}

sub fix_children {
}

=over 4

=item get_supported_languages ( [ string ROBOT ] )

I<Function>.
Gets supported languages, canonicalized.
In array context, returns array of supported languages.
In scalar context, returns arrayref to them.

=back

=cut

#FIXME: Inefficient.  Would be cached.
sub get_supported_languages {
    my $robot = shift;

    my @lang_list = ();
    if (%Conf::Conf) {    # configuration loaded.
        my $supported_lang;

        if ($robot and $robot ne '*') {
            $supported_lang = Conf::get_robot_conf($robot, 'supported_lang');
        } else {
            $supported_lang = $Conf::Conf{'supported_lang'};
        }

        my $language = Sympa::Language->instance;
        $language->push_lang;
        @lang_list =
            grep { $_ and $_ = $language->set_lang($_) }
            split /[\s,]+/, $supported_lang;
        $language->pop_lang;
    }
    @lang_list = ('en') unless @lang_list;
    return @lang_list if wantarray;
    return \@lang_list;
}

=over 4

=item get_list_params

I<Getter>.
Returns hashref to list parameter information.

=back

=cut

sub get_list_params {
    my $robot_id = shift;

    my $pinfo = tools::dup_var(\%Sympa::ListDef::pinfo);
    $pinfo->{'lang'}{'format'} = [tools::get_supported_languages($robot_id)];

    return $pinfo;
}

=over

=item lang2charset ( $lang )

Gets charset for e-mail messages sent by Sympa.

Parameters:

$lang - language.

Returns:

Charset name.
If it is not known, returns default charset.

=back

=cut

## FIXME: This would be moved to such as Site package.
sub lang2charset {
    my $lang = shift;

    my $locale2charset;
    if ($lang and %Conf::Conf    # configuration loaded
        and $locale2charset = $Conf::Conf{'locale2charset'}
        ) {
        foreach my $l (Sympa::Language::implicated_langs($lang)) {
            if (exists $locale2charset->{$l}) {
                return $locale2charset->{$l};
            }
        }
    }
    return 'utf-8';              # the last resort
}

=over 4

=item split_listname ( ROBOT_ID, MAILBOX )

XXX @todo doc

Note:
For C<-request> and C<-owner> suffix, this function returns
C<owner> and C<return_path> type, respectively.

=back

=cut

#FIXME: This should be moved to such as Robot package.
sub split_listname {
    my $robot_id = shift || '*';
    my $mailbox = shift;
    return unless defined $mailbox and length $mailbox;

    my $return_path_suffix =
        Conf::get_robot_conf($robot_id, 'return_path_suffix');
    my $regexp = join(
        '|',
        map { quotemeta $_ }
            grep { $_ and length $_ }
            split(
            /[\s,]+/, Conf::get_robot_conf($robot_id, 'list_check_suffixes')
            )
    );

    if (    $mailbox eq 'sympa'
        and $robot_id eq $Conf::Conf{'domain'}) {    # compat.
        return (undef, 'sympa');
    } elsif ($mailbox eq Conf::get_robot_conf($robot_id, 'email')
        or $robot_id eq $Conf::Conf{'domain'}
        and $mailbox eq $Conf::Conf{'email'}) {
        return (undef, 'sympa');
    } elsif ($mailbox eq Conf::get_robot_conf($robot_id, 'listmaster_email')
        or $robot_id eq $Conf::Conf{'domain'}
        and $mailbox eq $Conf::Conf{'listmaster_email'}) {
        return (undef, 'listmaster');
    } elsif ($mailbox =~ /^(\S+)$return_path_suffix$/) {    # -owner
        return ($1, 'return_path');
    } elsif (!$regexp) {
        return ($mailbox);
    } elsif ($mailbox =~ /^(\S+)-($regexp)$/) {
        my ($name, $suffix) = ($1, $2);
        my $type;

        if ($suffix eq 'request') {                         # -request
            $type = 'owner';
        } elsif ($suffix eq 'editor') {
            $type = 'editor';
        } elsif ($suffix eq 'subscribe') {
            $type = 'subscribe';
        } elsif ($suffix eq 'unsubscribe') {
            $type = 'unsubscribe';
        } else {
            $name = $mailbox;
            $type = 'UNKNOWN';
        }
        return ($name, $type);
    } else {
        return ($mailbox);
    }
}

# Old name: SympaspoolClassic::analyze_file_name().
# NOTE: This should be moved to Spool class.
sub unmarshal_metadata {
    Log::do_log('debug3', '(%s, %s, %s)', @_);
    my $spool_dir       = shift;
    my $marshalled      = shift;
    my $metadata_regexp = shift;
    my $metadata_keys   = shift;

    my $data;
    my @matches;
    unless (@matches = ($marshalled =~ /$metadata_regexp/)) {
        Log::do_log('debug',
            'File name %s does not have the proper format: %s',
            $marshalled, $metadata_regexp);
        return undef;
    }
    $data = {
        messagekey => $marshalled,
        map {
            my $value = shift @matches;
            (defined $value and length $value) ? ($_ => $value) : ();
            } @{$metadata_keys}
    };

    my ($robot_id, $listname, $type, $list, $priority);

    $robot_id = lc($data->{'domainpart'})
        if Conf::valid_robot($data->{'domainpart'}, just_try => 1);
    #FIXME: is this always needed?
    ($listname, $type) =
        tools::split_listname($robot_id || '*', $data->{'localpart'});
    if (defined $listname) {
        $list =
            Sympa::List->new($listname, $robot_id || '*', {'just_try' => 1});
    }

    ## Get priority
    #FIXME: is this always needed?
    if (exists $data->{'priority'}) {
        # Priority was given by metadata.
        ;
    } elsif ($type and $type eq 'listmaster') {
        ## highest priority
        $priority = 0;
    } elsif ($type and $type eq 'owner') {    # -request
        $priority = Conf::get_robot_conf($robot_id, 'request_priority');
    } elsif ($type and $type eq 'return_path') {    # -owner
        $priority = Conf::get_robot_conf($robot_id, 'owner_priority');
    } elsif ($type and $type eq 'sympa') {
        $priority = Conf::get_robot_conf($robot_id, 'sympa_priority');
    } elsif (ref $list eq 'Sympa::List') {
        $priority = $list->{'admin'}{'priority'};
    } else {
        $priority = Conf::get_robot_conf($robot_id, 'default_list_priority');
    }

    $data->{context} = $list || $robot_id || '*';
    $data->{'listname'} = $listname if $listname;
    $data->{'listtype'} = $type     if defined $type;
    $data->{'priority'} = $priority if defined $priority;

    Log::do_log('debug3', 'messagekey=%s, context=%s, priority=%s',
        $marshalled, $data->{context}, $data->{'priority'});

    return $data;
}

# NOTE: This should be moved to Spool class.
sub marshal_metadata {
    my $message         = shift;
    my $metadata_format = shift;
    my $metadata_keys   = shift;

    # Currently only "sympa@DOMAIN" and "listname@DOMAIN" are supported.
    my ($localpart, $domainpart);
    if (ref $message->{context} eq 'Sympa::List') {
        $localpart  = $message->{context}->{'name'};
        $domainpart = $message->{context}->{'domain'};
    } else {
        my $robot_id = $message->{context} || '*';
        $localpart  = Conf::get_robot_conf($robot_id, 'email');
        $domainpart = Conf::get_robot_conf($robot_id, 'domain');
    }

    my @args = map {
        if ($_ eq 'localpart') {
            $localpart;
        } elsif ($_ eq 'domainpart') {
            $domainpart;
        } elsif ($_ eq 'PID') {
            $PID;
        } elsif ($_ eq 'RAND') {
            int rand 10000;
        } elsif ($_ eq 'TIME') {
            Time::HiRes::time();
        } elsif (exists $message->{$_}
            and defined $message->{$_}
            and !ref($message->{$_})) {
            $message->{$_};
        } else {
            '';
        }
    } @{$metadata_keys};

    # Set "C" locale so that decimal point for "%f" will be ".".
    my $locale_numeric = POSIX::setlocale(POSIX::LC_NUMERIC());
    POSIX::setlocale(POSIX::LC_NUMERIC(), 'C');
    my $marshalled = sprintf $metadata_format, @args;
    POSIX::setlocale(POSIX::LC_NUMERIC(), $locale_numeric);
    return $marshalled;
}

# NOTE: This should be moved to Spool class.
sub store_spool {
    my $spool_dir       = shift;
    my $message         = shift;
    my $metadata_format = shift;
    my $metadata_keys   = shift;

    # At first content is stored into temporary file that has unique name and
    # is referred only by this function.
    my $tmppath = sprintf '%s/T.sympa@_tempfile.%s.%ld.%ld',
        $spool_dir, Sys::Hostname::hostname(), time, $PID;
    my $fh;
    unless (open $fh, '>', $tmppath) {
        die sprintf 'Cannot create %s: %s', $tmppath, $ERRNO;
    }
    print $fh $message->to_string;
    close $fh;

    # Rename temporary path to the file name including metadata.
    # Will retry up to five times.
    my $tries;
    for ($tries = 0; $tries < 5; $tries++) {
        my $marshalled =
            marshal_metadata($message, $metadata_format, $metadata_keys);
        my $path = $spool_dir . '/' . $marshalled;

        my $lock;
        unless ($lock = Sympa::LockedFile->new($path, -1, '+')) {
            next;
        }
        if (-e $path) {
            $lock->close;
            next;
        }

        unless (rename $tmppath, $path) {
            die sprintf 'Cannot create %s: %s', $path, $ERRNO;
        }
        $lock->close;
        return $marshalled;
    }

    unlink $tmppath;
    return undef;
}

1;
