# -*- Mode: perl; indent-tabs-mode: nil -*-
#
# The contents of this file are subject to the Mozilla Public
# License Version 1.1 (the "License"); you may not use this file
# except in compliance with the License. You may obtain a copy of
# the License at http://www.mozilla.org/MPL/
#
# Software distributed under the License is distributed on an "AS
# IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
# implied. See the License for the specific language governing
# rights and limitations under the License.
#
# The Original Code is the Bugzilla SecureMail Extension
#
# The Initial Developer of the Original Code is the Mozilla Foundation.
# Portions created by Mozilla are Copyright (C) 2008 Mozilla Foundation.
# All Rights Reserved.
#
# Contributor(s): Max Kanat-Alexander <mkanat@bugzilla.org>
#                 Gervase Markham <gerv@gerv.net>

package Bugzilla::Extension::SecureMail;
use strict;
use base qw(Bugzilla::Extension);

use Bugzilla::Group;
use Bugzilla::Object;
use Bugzilla::User;
use Bugzilla::Util qw(correct_urlbase trim trick_taint);
use Bugzilla::Error;
use Crypt::OpenPGP::KeyRing;
use Crypt::OpenPGP;
use Crypt::SMIME;

our $VERSION = '0.4';

##############################################################################
# Creating new columns
#
# secure_mail boolean in the 'groups' table - whether to send secure mail
# public_key text in the 'profiles' table - stores public key
##############################################################################
sub install_update_db {
    my ($self, $args) = @_;
    
    my $dbh = Bugzilla->dbh;
    $dbh->bz_add_column('groups', 'secure_mail', 
                        {TYPE => 'BOOLEAN', NOTNULL => 1, DEFAULT => 0});
    $dbh->bz_add_column('profiles', 'public_key', { TYPE => 'LONGTEXT' });
}

##############################################################################
# Maintaining new columns
##############################################################################

# Make sure generic functions know about the additional fields in the user
# and group objects.
sub object_columns {
    my ($self, $args) = @_;
    my $class = $args->{'class'};
    my $columns = $args->{'columns'};
    
    if ($class->isa('Bugzilla::Group')) {
        push(@$columns, 'secure_mail');
    }
    elsif ($class->isa('Bugzilla::User')) {
        push(@$columns, 'public_key');
    }
}

# Plug appropriate validators so we can check the validity of the two 
# fields created by this extension, when new values are submitted.
sub object_validators {
    my ($self, $args) = @_;
    my %args = %{ $args };
    my ($invocant, $validators) = @args{qw(class validators)};
    
    if ($invocant->isa('Bugzilla::Group')) {
        $validators->{'secure_mail'} = \&Bugzilla::Object::check_boolean;
    }
    elsif ($invocant->isa('Bugzilla::User')) {
        $validators->{'public_key'} = sub {
            my ($self, $value) = @_;
            $value = trim($value) || '';
            
            return $value if $value eq '';
            
            if ($value =~ /PUBLIC KEY/) {
                # PGP keys must be ASCII-armoured.
                my $ring = new Crypt::OpenPGP::KeyRing(Data => $value);
                $ring->read if $ring;
                if (!defined $ring || !scalar $ring->blocks) {
                    ThrowUserError('securemail_invalid_key');
                }
            }
            elsif ($value =~ /BEGIN CERTIFICATE/) {
                # S/MIME Keys must be in PEM format (Base64-encoded X.509)
                #
                # Crypt::SMIME seems not to like tainted values - it claims
                # they aren't scalars!
                trick_taint($value);

                my $smime = Crypt::SMIME->new();
                
                eval {
                    $smime->setPublicKey([$value]);
                };                
                if ($@) {
                    ThrowUserError('securemail_invalid_key');
                }
            }
            else {
                ThrowUserError('securemail_invalid_key');
            }
            
            return $value;
        };
    }
}

# When creating a 'group' object, set up the secure_mail field appropriately.
sub object_before_create {
    my ($self, $args) = @_;
    my $class = $args->{'class'};
    my $params = $args->{'params'};

    if ($class->isa('Bugzilla::Group')) {
        $params->{secure_mail} = Bugzilla->cgi->param('secure_mail');
    }
}

# On update, make sure the updating process knows about our new columns.
sub object_update_columns {
    my ($self, $args) = @_;
    my $object  = $args->{'object'};
    my $columns = $args->{'columns'};
    
    if ($object->isa('Bugzilla::Group')) {
        # This seems like a convenient moment to extract this value...
        $object->set('secure_mail', Bugzilla->cgi->param('secure_mail'));
        
        push(@$columns, 'secure_mail');
    }
    elsif ($object->isa('Bugzilla::User')) {
        push(@$columns, 'public_key');
    }
}

# Handle the setting and changing of the public key.
sub user_preferences {
    my ($self, $args) = @_;
    my $tab     = $args->{'current_tab'};
    my $save    = $args->{'save_changes'};
    my $handled = $args->{'handled'};
    my $vars    = $args->{'vars'};
    
    return unless $tab eq 'securemail';

    # Create a new user object so we don't mess with the main one, as we
    # don't know where it's been...
    my $user = new Bugzilla::User(Bugzilla->user->id);
    
    if ($save) {
        my $public_key = Bugzilla->input_params->{'public_key'};
        $user->set('public_key', $public_key);
        $user->update();
    }
    
    $vars->{'public_key'} = $user->{'public_key'};

    # Set the 'handled' scalar reference to true so that the caller
    # knows the panel name is valid and that an extension took care of it.
    $$handled = 1;
}

##############################################################################
# Encrypting the email
#
# A lot of this is getting objects for the user (and bug, if applicable) the
# email refers to.
##############################################################################
sub mailer_before_send {
    my ($self, $args) = @_;

    my $email = $args->{'email'};
    
    # Decide whether to make secure.
    # This is a bit of a hack; it would be nice if it were more clear 
    # what sort a particular email is.
    my $is_bugmail      = $email->header('X-Bugzilla-Status');
    my $is_passwordmail = !$is_bugmail && ($email->body =~ /cfmpw.*cxlpw/s);
    
    if ($is_bugmail || $is_passwordmail) {
        # Convert the email's To address into a User object
        my $login = $email->header('To');
        
        my $emailsuffix = Bugzilla->params->{'emailsuffix'};
        $login =~ s/$emailsuffix$//;
        my $user = new Bugzilla::User({ name => $login });
        
        # If finding the user fails for some reason, but we determine we 
        # should be encrypting, we want to make the mail safe. An empty key 
        # does that.
        my $public_key = $user ? $user->{'public_key'} : '';
    
        my $make_secure = 0;
        
        if ($is_bugmail) {
            # This is also a bit of a hack, but there's no header with the 
            # bug ID in. So we take the first number in the subject.
            my $bug_id = ($email->header('Subject') =~ /^[^\d]+(\d+)/);
            my $bug = new Bugzilla::Bug($bug_id);
            # If we can't find a bug object to check its groups, fail safe.
            if (!$bug || grep($_->{secure_mail}, @{ $bug->groups_in })) {
                $make_secure = 1;
            }
        }
        elsif ($is_passwordmail) {
            # If we don't know who the user is, something funny is going on.
            # So don't send the password mail. The 'user' will be asked to 
            # contact the admin.
            if (!$user || grep($_->{secure_mail}, @{ $user->groups })) {
                $make_secure = 1;
            }      
        }
        
        if ($make_secure) {
            _make_secure($email, $public_key, $is_bugmail);
        }
    }
}

sub _make_secure {
    my ($email, $key, $is_bugmail) = @_;

    my $bug_id = undef;
    my $subject = $email->header('Subject');

    # We only change the subject if it's a bugmail; password mails don't have
    # confidential information in the subject.
    if ($is_bugmail) {            
        $bug_id = ($subject =~ /^[^\d]+(\d+)/);
        
        my $new_subject = $subject;
        # (This won't work if somebody's changed the Subject format...)
        $new_subject =~ s/($bug_id\])\s+(.*)$/$1 (Secure bug updated)/;
        $email->header_set('Subject', $new_subject);
    }

    if ($key && $key =~ /PUBLIC KEY/) {
        ##################
        # PGP Encryption #
        ##################
        my $body = $email->body;
        if ($is_bugmail) {
            # Subject gets placed in the body so it can still be read
            $body = "Subject: $subject\n\n" . $body;
        }
        
        my $pubring = new Crypt::OpenPGP::KeyRing(Data => $key);
        my $pgp = new Crypt::OpenPGP(PubRing => $pubring);
        
        # "@" matches every key in the public key ring, which is fine, 
        # because there's only one key in our keyring.
        my $encrypted = $pgp->encrypt(Data       => $body, 
                                      Recipients => "@", 
                                      Armour     => 1);
        if (defined $encrypted) {
            $email->body_set($encrypted);
        }
        else {
            $email->body_set('Error during Encryption: ' . $pgp->errstr);
        }
    }
    elsif ($key && $key =~ /BEGIN CERTIFICATE/) {
        #####################
        # S/MIME Encryption #
        #####################
        my $smime = Crypt::SMIME->new();
        my $encrypted;
        
        eval {
            $smime->setPublicKey([$key]);                
            $encrypted = $smime->encrypt($email->as_string());
        };
        
        if (!$@) {      
            # We can't replace the Email::MIME object, so we have to swap
            # out its component parts.
            my $enc_obj = new Email::MIME($encrypted);
            $email->header_obj_set($enc_obj->header_obj());
            $email->body_set($enc_obj->body());
        }
        else {
            $email->body_set('Error during Encryption: ' . $@);
        }
    }
    else {
        # No encryption key provided; send a generic, safe email.
        my $template = Bugzilla->template;
        my $message;
        my $vars = {
          'urlbase'    => correct_urlbase(),
          'bug_id'     => $bug_id,
          'maintainer' => Bugzilla->params->{'maintainer'}
        };
        
        $template->process('account/email/encryption-required.txt.tmpl',
                           $vars, \$message)
          || ThrowTemplateError($template->error());
        
        $email->body_set($message);
    }
}

__PACKAGE__->NAME;
