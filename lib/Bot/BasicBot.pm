=head1 NAME

Bot::BasicBot - simple irc bot baseclass

=head1 SYNOPSIS

  # with all defaults
  Bot::BasicBot->new( channels => ["#bottest"] )->run();

  # with all known options
  Bot::BasicBot->new( channels => ["#bottest"],

                      server => "irc.example.com",
                      port   => "6667",

                      nick      => "basicbot",
                      alt_nicks => ["bbot", "simplebot"],
                      username  => "bot",
                      name      => "Yet Another Bot",

                      ignore_list => [qw(dipsy dadadodo laotse)],
                )->run();

=head1 DESCRIPTION

Basic bot system designed to make it easy to do simple bots, optionally
forking longer processes (like searches) concurrently in the background.

There are several examples of bots using Bot::BasicBot in the examples/
folder in the Bot::BasicBot tarball. If you installed Bot::BasicBot through
CPAN, see http://jerakeen.org/programming/Bot-BasicBot for more docs and
examples.

=head1 METHODS

=cut

package Bot::BasicBot;

use strict;
use warnings;

use Carp;
use Exporter;
use POE::Kernel;
use POE::Session;
use POE::Wheel::Run;
use POE::Filter::Line;
use POE::Component::IRC;

our $VERSION = 0.30;

use base qw( Exporter );
our @EXPORT  = qw( say emote );

our $RECONNECT_TIMEOUT = 500;

=head2 new( key => value, .. )

Creates a new instance of the class.  Name value pairs may be passed
which will have the same effect as calling the method of that name
with the value supplied.

eg:

  Bot::BasicBot->new( nick => 'superbot', channels => [ '#superheroes' ] );

=cut

sub new {
    my $class = shift;
    my $self = bless {}, $class;

    $self->{IRCNAME} = 'wanna'.int(rand(100000));
    $self->{ALIASNAME} = 'pony'.int(rand(100000));

    # call the set methods
    my %args = @_;
    foreach my $method ( keys %args ) {
        if ( $self->can($method) ) {
            $self->$method( $args{$method} );
        } else {
            $self->{$method} = $args{$method};
            #croak "Invalid argument '$method'";
        }
    }

    $self->init or return undef;

    return $self;
}

=head2 init()

called when the bot is created, as part of new(). Override to provide
your own init. Return a true value for a successful init, or undef if
you failed, in which case new() will return undef.

=cut

sub init { 1; }

=head2 run()

Runs the bot.  Hands the control over to the POE core.

=cut

sub run {
    my $self = shift;

    # yep, we use irc
    POE::Component::IRC->new($self->{IRCNAME})
      or die "Can't instantiate new IRC component!\n";

    # create the callbacks to the object states
    POE::Session->create(
        object_states => [
            $self => {
                _start => "start_state",
                _stop  => "stop_state",

                irc_001          => "irc_001_state",
                irc_msg          => "irc_said_state",
                irc_public       => "irc_said_state",
                irc_ctcp_action  => "irc_emoted_state",
                irc_ping         => "irc_ping_state",
                reconnect        => "reconnect",

                irc_disconnected => "irc_disconnected_state",
                irc_error        => "irc_error_state",

                irc_join         => "irc_chanjoin_state",
                irc_part         => "irc_chanpart_state",

                fork_close => "fork_close_state",
                fork_error => "fork_error_state",
                
                tick => "tick_state",
            }
        ]
    );

    # and say that we want to recive said messages
    $poe_kernel->post( $self->{IRCNAME} => register => 'all' );

    # run
    $poe_kernel->run() unless $self->{no_run};
}

=head2 said($args)

This is the main method that you'll want to override in your subclass -
it's the one called by default whenever someone says anything that we
can hear, either in a public channel or to us in private that we
shouldn't ignore.

You'll be passed a hashref that contains the arguments described below. 
Feel free to alter the values of this hash - it won't be used later on.

=over 4

=item who

Who said it (the nick that said it)

=item channel

The channel in which they said it.  Has special value "msg" if it
was in a message.  Actually, as you can send a message to many
channels at once in the IRC spec, but no-one actually does this
so it's just the first one in the list

=item body

The body of the message (i.e. the actual text)

=item address

The text that indicates how we were addressed.  Contains the string
"msg" for private messages, otherwise contains the string off the text
that was stripped off the front of the message if we were addressed,
e.g. "Nick: ".  Obviously this can be simply checked for truth if you
just want to know if you were addressed or not.

=back

You should return what you want to say.  This can either be a simple
string (which will be sent back to whoever was talking to you as a
message or in public depending on how they were talking) or a hashref
that contains values that are compatible with say (just changing
the body and returning the structure you were passed works very well.)

Returning undef will cause nothing to be said.

=cut

sub said { undef }

=head2 emoted($args)

This is a secondary method that you may wish to override. It gets called
when someone in channel 'emotes', instead of talking. In its default
configuration, it will simply pass anything emoted on channel through to
the C<said> handler.

C<emoted> receives the same data hash as C<said>.

=cut

sub emoted {
    shift->said(@_);
}

=head2 chanjoin($mess)

Called when someone joins a channel. $mess is an object similar to a
said() message, $mess->{who} is the nick of the user who joined,
$mess->{channel} is the channel they joined.

This is a do-nothing implementation, override this in your subclass.

=cut

sub chanjoin { undef }

=head2 chanpart($mess)

Called when someone leaves a channel. $mess is an object similar to a
said() message, $mess->{who} is the nick of the user who left,
$mess->{channel} is the channel they left.

This is a do-nothing implementation, override this in your subclass.

=cut

sub chanpart { undef }


=head2 tick()

This is an event called every regularly. The function should return the
amount of time untill the tick event should next be called. The default
tick is called 5 seconds after the bot starts, and the default
implementation returns '0', which disables the tick. Override this and
return non-zero values to have an ongoing tick event.

Call the C<schedule_tick> event to schedule a tick event without waiting
for the next tick.

=cut

sub tick { return 0; }

=head2 schedule_tick(time)

Causes the C<tick> event to be called in 'time' seconds (or 5 seconds if
time is left unspecified). Note that if the tick event is due to be
called already, this will override it, you can't schedule multiple
future events with this funtction.

=cut

sub schedule_tick {
  my $self = shift;
  my $time = shift || 5;
  $self->{kernel}->delay( tick => $time );
}

=head2 forkit

This method allows you to fork arbitrary background processes. They
will run concurrently with the main bot, returning their output to a
handler routine. You should call C<forkit> in response to specific
events in your C<said> routine, particularly for longer running
processes like searches, which will block the bot from receiving or
sending on channel whilst they take place if you don't fork them.

C<forkit> takes the following arguments:

=over 4

=item run

A coderef to the routine which you want to run. Bear in mind that the
routine doesn't automatically get the text of the query - you'll need
to pass it in C<arguments> (see below) if you want to use it at all.

Apart from that, your C<run> routine just needs to print its output to
C<STDOUT>, and it will be passed on to your designated handler.

=item handler

Optional. A method name within your current package which we can
return the routine's data to. Defaults to the built-in method
C<say_fork_return> (which simply sends data to channel).

=item body

Optional. Use this to pass on the body of the incoming message that
triggered you to fork this process. Useful for interactive proceses
such as searches, so that you can act on specific terms in the user's
instructions.

=item who

The nick of who you want any response to reach (optional inside a
channel.)

=item channel

Where you want to say it to them in.  This may be the special channel
"msg" if you want to speak to them directly

=item address

Optional.  Setting this to a true value causes the person to be
addressed (i.e. to have "Nick: " prepended to the front of returned
message text if the response is going to a public forum.

=item arguments

Optional. This should be an anonymous array of values, which will be
passed to your C<run> routine. Bear in mind that this is not
intelligent - it will blindly spew arguments at C<run> in the order
that you specify them, and it is the responsibility of your C<run>
routine to pick them up and make sense of them.

=back

=cut

sub forkit {
    my $self = shift;
    my $args;
    if (ref($_[0])) {
        $args = shift;
    } else {
        my %args = @_;
        $args = \%args;
    }

    return undef unless $args->{run};

    $args->{handler}   = $args->{handler}   || "fork_said";
    $args->{arguments} = $args->{arguments} || [];

    #install a new handler in the POE kernel pointing to
    # $self->{$args{handler}}
    $poe_kernel->state( $args->{handler}, $self );

    my $run;
    if ( ref( $args->{run} ) =~ /^CODE/ ) {
        $run = sub { &{ $args->{run} }( $args->{body}, @{ $args->{arguments} } ) };
    } else {
        $run = $args->{run};
    }

    my $wheel = POE::Wheel::Run->new(
        Program      => $run,
        StdoutFilter => POE::Filter::Line->new(),
        StderrFilter => POE::Filter::Line->new(),
        StdoutEvent  => "$args->{handler}",
        StderrEvent  => "fork_error",
        CloseEvent   => "fork_close"
    );

    # store the wheel object in our bot, so we can retrieve/delete easily

    $self->{forks}->{ $wheel->ID } = {
        wheel => $wheel,
        args  => {
            channel => $args->{channel},
            who     => $args->{who},
            address => $args->{address}
        }
    };
    return undef;
}

=head2 say( key => value, .. )

Say something to someone.  You should pass the following arguments:

=over 4

=item who

The nick of who you are saying this to (optional inside a channel.)

=item channel

Where you want to say it to them in.  This may be the special channel
"msg" if you want to speak to them directly

=item body

The body of the message.  I.e. what you want to say.

=item address

Optional.  Setting this to a true value causes the person to be
addressed (i.e. to have "Nick: " prepended to the front of the message
text if this message is going to a pulbic forum.

=back

You can also make non-OO calls to C<say>, which will be interpreted as
coming from a process spawned by C<forkit>. The routine will serialise
any data it is sent, and throw it to STDOUT, where L<POE::Wheel::Run> can
pass it on to a handler.

=cut

sub say {

    # If we're called without an object ref, then we're handling saying
    # stuff from inside a forked subroutine, so we'll freeze it, and toss
    # it out on STDOUT so that POE::Wheel::Run's handler can pick it up.
    if ( !ref( $_[0] ) ) {
        print $_[0] . "\n";
        return 1;
    }

    # Otherwise, this is a standard object method

    my $self = shift;
    my $args;
    if (ref($_[0])) {
        $args = shift;
    } else {
        my %args = @_;
        $args = \%args;
    }

    my $body = $args->{body};

    # add the "Foo: bar" at the start
    $body = "$args->{who}: $body"
      if ( $args->{channel} ne "msg" and $args->{address} );

    # work out who we're going to send the message to
    my $who = ( $args->{channel} eq "msg" ) ? $args->{who} : $args->{channel};

    unless ( $who && $body ) {
        print STDERR "Can't PRIVMSG without target and body\n";
        print STDERR " who = '$who'\n body = '$body'\n";
        return;
    }

    # if we have a long body, split it up..
    my @bodies = $body =~ m!(.{1,300})!g;

    # post an event that will send the message
    for (@bodies) {
        $poe_kernel->post( $self->{IRCNAME}, 'privmsg', $who, $_ );
    }
}

=head2 emote( key => value, .. )

C<emote> will return data to channel, but emoted (as if you'd said "/me
writes a spiffy new bot" in most clients). It takes the same arguments
as C<say>, listed above.

=cut

sub emote {

    # If we're called without an object ref, then we're handling emoting
    # stuff from inside a forked subroutine, so we'll freeze it, and
    # toss it out on STDOUT so that POE::Wheel::Run's handler can pick
    # it up.
    if ( !ref( $_[0] ) ) {
        print $_[0] . "\n";
        return 1;
    }

    # Otherwise, this is a standard object method

    my $self = shift;
    my $args;
    if (ref($_[0])) {
        $args = shift;
    } else {
        my %args = @_;
        $args = \%args;
    }

    my $body = $args->{body};

    # Work out who we're going to send the message to
    my $who =
      ( $args->{channel} eq "msg" )
      ? $args->{who}
      : $args->{channel};

    # post an event that will send the message
    # if there's a better way of sending actions i'd love to know - jw
    # me too; i'll look at it in v0.5 - sb

    $poe_kernel->post( $self->{IRCNAME}, 'privmsg', $who, "\cAACTION " . $body . "\cA" );
}

=head2 reply($mess, $body)

Reply to a message $mess. Will reply to an incoming message
with the text '$body', in a privmsg if $mess was a privmsg, in channel if
not, and prefixes if $mess was prefixed. Mostly a shortcut method.

=cut

sub reply {
    my $self = shift;
    my ($mess, $body) = @_;
    my %hash = %$mess;
    $hash{body} = $body;
    return $self->say(%hash);
}

=head2 fork_said

C<fork_said> is really an internal method, the default handler
for output from a process forked by C<forkit>. It actually takes
its input from a non-object call to C<say>, thaws the data, picks
up arguments, and throws them back at C<say> again. Don't ask - this
is the way L<POE::Wheel::Run> works, and this jiggery-pokery gives us a
nice object interface.

=cut

sub fork_said {
    my ( $self, $body, $wheel_id ) = @_[ 0, ARG0, ARG1 ];
    chomp($body);    # remove newline necessary to move data;

    # pick up the default arguments we squirreled away earlier
    my $args = $self->{forks}->{$wheel_id}->{args};
    $args->{body} = $body;

    $self->say($args);
}

=head2 help

This is the other method that you should override.  This is the text
that the bot will respond to if someone simply says help to it.  This
should be considered a special case which you should not attempt to
process yourself.  Saying help to a bot should have no side effects
whatsoever apart from returning this text.

=cut

sub help { "Sorry, this bot has no interactive help." }

=head2 connected

An optional method to override, gets called after we have connected
to the server

=cut

sub connected { undef }

=head1 ACCESS METHODS

Get or set methods.  Changing most of these values when connected
won't cause sideffects.  e.g. changing the server will not
cause a disconnect and a reconnect to another server.

Attributes that accept multiple values always return lists and
either accept an arrayref or a complete list as an argument.

The usual way of calling these is as keys to the hash passed to the
'new' method.

=head2 server

The server we're going to connect to.  Defaults to
"london.rhizomatic.net".

=cut

sub server {
    my $self = shift;
    $self->{server} = shift if @_;
    return $self->{server} || "irc.perl.org";
}

=head2 port

The port we're going to use.  Defaults to "6667"

=cut

sub port {
    my $self = shift;
    $self->{port} = shift if @_;
    return $self->{port} || "6667";
}

=head2 nick

The nick we're going to use.  Defaults to five random letters
and numbers followed by the word "bot"

=cut

sub nick {
    my $self = shift;
    $self->{nick} = shift if @_;
    return $self->{nick} ||= _random_nick();
}

sub _random_nick {
    my @things = ( 'a' .. 'z' );
    return join '', ( map { @things[ rand @things ] } 0 .. 4 ), "bot";
}

=head2 alt_nicks

Alternate nicks that this bot will be known by.  These are not nicks
that the bot will try if it's main nick is taken, but rather other
nicks that the bot will recognise if it is addressed in a public
channel as the nick.  This is useful for bots that are replacements
for other bots...e.g, your bot can answer to the name "infobot: "
even though it isn't really.

=cut

sub alt_nicks {
    my $self = shift;
    if (@_) {

        # make sure we copy
        my @args = ( ref $_[0] eq "ARRAY" ) ? @{ $_[0] } : @_;
        $self->{alt_nicks} = \@args;
    }
    @{ $self->{alt_nicks} || [] };
}

=head2 username

The username we'll claim to have at our ip/domain.  By default this
will be the same as our nick.

=cut

sub username {
    my $self = shift;
    $self->{username} = shift if @_;
    $self->{username} or $self->nick;
}

=head2 name

The name that the bot will identify itself as.  Defaults to
"$nick bot" where $nick is the nick that the bot uses.

=cut

sub name {
    my $self = shift;
    $self->{name} = shift if @_;
    $_[0]->{name} or $self->nick . " bot";
}

=head2 channels

The channels we're going to connect to.

=cut

sub channels {
    my $self = shift;
    if (@_) {

        # make sure we copy
        my @args = ( ref $_[0] eq "ARRAY" ) ? @{ $_[0] } : @_;
        $self->{channels} = \@args;
    }
    @{ $self->{channels} || [] };
}

=head2 quit_message

The quit message.  Defaults to "Bye".

=cut

sub quit_message {
    my $self = shift;
    $self->{quit_message} = shift if @_;
    defined( $self->{quit_message} ) ? $self->{quit_message} : "Bye";
}

=head2 ignore_list

The list of irc nicks to ignore B<public> messages from (normally
other bots.)  Useful for stopping bot cascades.

=cut

sub ignore_list {
    my $self = shift;
    if (@_) {

        # make sure we copy
        my @args = ( ref $_[0] eq "ARRAY" ) ? @{ $_[0] } : @_;
        $self->{ignore_list} = \@args;
    }
    @{ $self->{ignore_list} || [] };
}

=head1 STATES

These are the POE states that we register in order to listen for IRC
events. For the most part you don't need to worry about these, unless
you want to override them to do something clever.

=head2 start_state

Called when we start.  Used to fire a "connect to irc server event"

=cut

sub start_state {
    my ( $self, $kernel, $session ) = @_[ OBJECT, KERNEL, SESSION ];
    $self->{kernel} = $kernel;
    $self->{session} = $session;

    $self->log("Control session start\n");

    # Make an alias for our session, to keep it from getting GC'ed.
    $kernel->alias_set($self->{ALIASNAME});

    # Ask the IRC component to send us all IRC events it receives. This
    # is the easy, indiscriminate way to do it.
    $kernel->post($self->{IRCNAME}, 'register', 'all');

    $kernel->delay('reconnect', 1 );

    $kernel->delay('tick', 30);
}

=head2 reconnect

Connects the bot to the IRC server. Called 1 second after the 'start'
event.

in an ideal world, this will never get called again - we schedule it for 'x'
seconds in the future, and whenever we see a server ping we reset this
counter again. This means that it'll get run if we haven't seen anything
from the server for a while, so we can assume that something bad has
happened. At that point we shotgun the IRC session and restart
everything, so we reconnect to the server.

This is by far the most reliable way I have found of ensuring that a bot
will reconnect to a server after it's lost a network connection for some
reason.

By default, the timeout is 300 seconds. It can be set by changing
$Bot::BasicBot::RECONNECT_TIMEOUT.

=cut

sub reconnect {
    my ( $self, $kernel, $session ) = @_[ OBJECT, KERNEL, SESSION ];

    $self->log("Trying to connect to server.\n");

    $kernel->call( $self->{IRCNAME}, 'disconnect' );
    $kernel->call( $self->{IRCNAME}, 'shutdown' );
    POE::Component::IRC->new($self->{IRCNAME});
    $kernel->post( $self->{IRCNAME}, 'register', 'all' );

    $kernel->post($self->{IRCNAME}, 'connect',
        {
            Debug    => 0,
            Nick     => $self->nick,
            Server   => $self->server,
            Port     => $self->port,
            Username => $self->username,
            Ircname  => $self->name,
        }
    );
    $kernel->delay('reconnect', $RECONNECT_TIMEOUT);
}

=head2 stop_state

Called when we're stopping.  Shutdown the bot correctly.

=cut

sub stop_state {
    my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];

    $self->log("Control session stopped.\n");

    $kernel->post( $self->{IRCNAME}, 'quit', $self->quit_message );
    $kernel->alias_remove($self->{ALIASNAME});
}

=head2 irc_001_state

Called when we connect to the irc server.  This is used to tell
the irc server that we'd quite like to join the channels.

We also ignore ourselves.  We don't want to hear what we have to say.

=cut

sub irc_001_state {
    my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];

    $self->log("IRC server ready\n");

    # ignore all messages from ourselves
    $kernel->post( $self->{IRCNAME}, 'ignore', $self->nick );

    # connect to the channel
    foreach my $channel ( $self->channels ) {
        $self->log("Trying to connect to '$channel'\n");
        $kernel->post( $self->{IRCNAME}, 'join', $channel );
    }

    $self->schedule_tick(5);

    $self->connected();
}

=head2 irc_disconnected_state

Called if we are disconnected from the server. 
Logs the error and schedules a reconnect event.

=cut

sub irc_disconnected_state {
    my ( $self, $kernel, $server ) = @_[ OBJECT, KERNEL, ARG0 ];
    $self->log("Lost connection to server $server.\n");
    $kernel->delay('reconnect', 30);
}

=head2 irc_error_state

Called if there is an irc server error.
Logs the error and schedules a reconnect event.

=cut

sub irc_error_state {
    my ( $self, $err, $kernel ) = @_[ OBJECT, ARG0, KERNEL ];
    $self->log("Server error occurred! $err\n");
    $kernel->delay('reconnect', 30);
}

=head2 irc_kicked_state

Called if we get kicked.  If we're kicked then it's best to do
nothing.  Bots are normally called in wrapper that restarts them
if we die, which may end us up in a busy loop.  Anyway, if we're not
wanted, the best thing to do would be to hang around off channel.

=cut

sub irc_kicked_state {
    my ( $self, $err ) = @_[ OBJECT, ARG0 ];
    $self->log("Kick ($err)\n");
}

=head2 irc_join_state

Called if someone joins.  Used for nick tracking

=cut

sub irc_join_state {
    my ( $self, $nick ) = @_[ OBJECT, ARG0 ];
}

=head2 irc_nick_state

Called if someone changes nick.  Used for nick tracking.

=cut

sub irc_nick_state {
    my ( $self, $nick, $newnick ) = @_[ OBJECT, ARG0, ARG1 ];
}

=head2 irc_said_state

Called if we recieve a private or public message.  This
formats it into a nicer format and calls 'said'

=cut

sub irc_said_state {
    $_[KERNEL]->delay( 'reconnect', $RECONNECT_TIMEOUT );
    irc_received_state( 'said', 'say', @_ );
}

=head2 irc_emoted_state

Called if someone "emotes" on channel, rather than directly saying
something. Currently passes the emote striaght to C<irc_said_state>
which deals with it as if it was a spoken phrase.

=cut

sub irc_emoted_state {
    $_[KERNEL]->delay( 'reconnect', $RECONNECT_TIMEOUT );
    irc_received_state( 'emoted', 'emote', @_ );
}

=head2 irc_received_state

Called by C<irc_said_state> and C<irc_emoted_state> in order to format
channel input into a more copable-with format.

=cut

sub irc_received_state {
    my $received = shift;
    my $respond  = shift;
    my ( $self, $nick, $to, $body ) = @_[ OBJECT, ARG0, ARG1, ARG2 ];

    my $return;

    my $mess = {};

    # work out who it was from
    $mess->{who} = $self->nick_strip($nick);

    # right, get the list of places this message was
    # sent to and work out the first one that we're
    # either a memeber of is is our nick.
    # The IRC protocol allows messages to be sent to multiple
    # targets, which is pretty clever. However, noone actually
    # /does/ this, so we can get away with this:

    my $channel = $to->[0];
    if ( $channel eq $self->nick ) {
        $mess->{channel} = "msg";
        $mess->{address} = "msg";
    } else {
        $mess->{channel} = $channel;
    }

    # okay, work out if we're addressed or not

    $mess->{body} = $body;
    unless ( $mess->{channel} eq "msg" ) {
        my $nick = $self->nick;
        ( $mess->{address} ) = $mess->{body} =~ s/^(\Q$nick\E\s*[:,-]?)//;

        foreach $nick ( $self->alt_nicks ) {
            last if $self->{address};

            ( $mess->{address} ) = $mess->{body} =~ s/^(\Q$nick\E\s*[:,-])//;
        }
    }

    # strip off whitespace before and after the message
    $mess->{body} =~ s/^\s+//;
    $mess->{body} =~ s/\s+$//;

    # okay, we got this far.  Better log this.  This needs changing
    # to a nice format.  Oooh, I could spit out sax events... (mf)
    #$self->log(
    #    join('||', $mess->{who}, $mess->{channel}, $mess->{address}, $mess->{body})
    #    ."\n");

    # check if someone was asking for help
    if ( $mess->{address} && ( $mess->{body} =~ /^help/i ) ) {
        $self->log("Invoking help for '$mess->{who}'\n");
        $mess->{body} = $self->help($mess);
        $self->say($mess);
        return;
    }

    # okay, call the said/emoted method
    $respond = $self->$received($mess);

    ### what did we get back?

    # nothing? Say nothing then
    return unless defined($return);

    # a string?  Say it how we were addressed then
    unless ( ref($return) ) {
        $mess->{body} = $return;
        $self->$respond($mess);
        return;
    }

    # just say what we were handed back
    $self->$respond($return);
}

=head2 irc_ping_state

The most reliable way I've found of doing auto-server-rejoin is to listen for
pings. Every ping we get, we put off rejoining the server for another few mins.
If we haven't heard a ping in a while, the rejoin code will get called.

Recently, I've adapted this for servers that don't send pings very often,
and reset the counter any time _anything_ interesting happens.

You can change the amount of time the bot waits between events before calling
a reconnect event by changing $Bot::BasicBot::RECONNECT_TIMEOUT to a value in
seconds. The default is '500'.

=cut

sub irc_ping_state {
    $_[KERNEL]->delay( 'reconnect', $RECONNECT_TIMEOUT );
}

=head2 irc_chanjoin_state

Called if someone joins a channel.

=cut

sub irc_chanjoin_state {
    $_[KERNEL]->delay( 'reconnect', $RECONNECT_TIMEOUT );
    irc_chan_received_state( 'chanjoin', 'say', @_ );
}

=head2 irc_chanpart_state

Called if someone parts a channel.

=cut

sub irc_chanpart_state {
    $_[KERNEL]->delay( 'reconnect', $RECONNECT_TIMEOUT );
    irc_chan_received_state( 'chanpart', 'say', @_ );
}

=head2 irc_chan_received_state

Called by C<irc_chanjoin_state> and C<irc_chanpart_state> in order to format
channel joins and parts into a more copable-with format.

=cut

sub irc_chan_received_state {
    my $received = shift;
    my $respond  = shift;
    my ( $self, $nick, $channel ) = @_[ OBJECT, ARG0, ARG1 ];

    my $return;

    my $mess = {};

    $mess->{who} = $self->nick_strip($nick);

    #if it's us (the bot) joining then we need to ignore the join
    if($mess->{who} eq $self->nick) { return; }

    $mess->{channel} = $channel;
    $mess->{body} = $received; #chanjoin or chanpart
    $mess->{address} = "chan";

    #$self->log(
    #    join('||', $mess->{who}, $mess->{channel}, $mess->{address}, $mess->{body})
    #    ."\n");

    # okay, call the chanjoin/chanpart method
    $respond = $self->$received($mess);

    ### what did we get back?

    # nothing? Say nothing then
    return unless defined($return);

    # a string?  Say it how we were addressed then
    unless ( ref($return) ) {
      $mess->{body} = $return;
      $self->$respond($mess);
      return;
    }

    # just say what we were handed back
    $self->$respond($return);
}


=head2 fork_close_state

Called whenever a process forked by L<POE::Wheel::Run> (in C<forkit>)
terminates, and allows us to delete the object and associated data
from memory.

=cut

sub fork_close_state {
    my ( $self, $wheel_id ) = @_[ 0, ARG0 ];

    #warn "received close event from wheel $wheel_id\n";
    delete $self->{forks}->{$wheel_id};
}

=head2 fork_error_state

Called if a process forked by L<POE::Wheel::Run> (in C<forkit>) hits
an error condition for any reason. Does nothing, but can be overloaded
in derived classes to be more useful

=cut

sub fork_error_state { }

=head2 tick_state

the POE state for the tick event. Reschedules a tick event for the future
if the tick method returned a value.

=cut

sub tick_state {
    my ( $self, $kernel, $heap ) = @_[ OBJECT, KERNEL, HEAP ];
    my $delay = $self->tick();
    $self->schedule_tick($delay) if $delay;
}

=head1 OTHER METHODS

=head2 AUTOLOAD

Bot::BasicBot implements AUTOLOAD for sending arbitrary states to the
underlying L<POE::Component::IRC> compoment. So for a $bot object, sending

    $bot->foo("bar");

is equivalent to

    $poe_kernel->post(BASICBOT_ALIAS, "foo", "bar");

=cut

sub AUTOLOAD {
    my $self = shift;
    our $AUTOLOAD;
    $AUTOLOAD =~ s/.*:://;
    $poe_kernel->post( $self->{IRCNAME}, $AUTOLOAD, @_ );
}

=head2 log

Logs the message. This method merely prints to STDERR - If you want smarter
logging, override this method - it will have simple text strings passed in
@_.

=cut

sub log {
    my $self = shift;
    for (@_) {
      chomp;
      print STDERR "$_\n";
    }
}

=head2 ignore_nick($nick)

Return true if this nick should be ignored.  Ignores anything in
the ignore list or with a nick ending in "bot".

=cut

sub ignore_nick {
    local $_;
    my $self = shift;
    my $nick = shift;
    return grep { $nick eq $_ } @{ $self->{ignore_list} };
}

=head2 nick_strip

Takes a nick and hostname (of the form "nick!hostname") and
returns just the nick

=cut

sub nick_strip {
    my $self = shift;
    my $combined = shift;
    my ($nick) = $combined =~ m/(.*?)!/;

    return $nick;
}

=head1 AUTHOR

Tom Insam E<lt>tom@jerakeen.orgE<gt>

This program is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

=head1 CREDITS

The initial version of Bot::BasicBot was written by Mark Fowler,
and many thanks are due to him.

Nice code for dealing with emotes thanks to Jo Walsh.

Various patches from Tom Insam, including much improved rejoining,
AUTOLOAD stuff, better interactive help, and a few API tidies.

Maintainership for a while was in the hands of Simon Kent
E<lt>simon@hitherto.netE<gt>. Don't know what he did. :-)

I recieved patches for tracking joins and parts from Silver, sat on
them for two months, and have finally applied them. Thanks, dude. He also
sent me changes for the tick event API, which made sense.

=head1 SYSTEM REQUIREMENTS

Bot::BasicBot is based on POE, and really needs the latest version as
of writing (0.22), since POE::Wheel::Run (used for forking) is still
under development, and the interface recently changed. With earlier
versions of POE, forking will not work, and the makefile process will
carp if you have < 0.22. Sorry.

You also need POE::Component::IRC.

=head1 BUGS

During the make, make test make install process, POE will moan about
its kernel not being run. I'll try and gag it in future releases, but
hey, release early, release often, and it's not a fatal error. It just
looks untidy.

Don't call your bot "0".

Nick tracking blatantly doesn't work yet. In Progress.

C<fork_error_state> handlers sometimes seem to cause the bot to
segfault. I'm not yet sure if this is a POE::Wheel::Run problem, or a
problem in our implementation.

=head1 SEE ALSO

L<POE>, L<POE::Component::IRC>

Possibly Infobot, at http://www.infobot.org

=cut

1;