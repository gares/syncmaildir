SYNC MAIL DIR
=============

Sync Mail Dir (`smd`) is a set of tools to synchronize a pair of mailboxes
in Maildir format.  It is Free Software, released under the terms of GPLv3,
Copyright © 2008-2018 Enrico Tassi.

It differs from other solutions in terms of performances and lower
installation requirements.  The widespread solution IMAP-server plus
[OfflineIMAP](http://software.complete.org/software/projects/show/offlineimap)
requires an IMAP server to be installed.  Alternatively
[Maildirsync](http://hacks.dlux.hu/maildirsync/) requires no IMAP server,
just ssh, but it used to load my laptop CPU too much and it seems its
development stopped in 2004.  Other general purpose tools like rsync or
unison may work too, but not benefit from the fact that they are
synchronizing mail messages.  Sync Mail Dir is similar to Maildirsync in its
design and requirements, but is more efficient, having its mechanisms
written in C (around 900 lines), while policies are written in scripting
languages like Lua and shell script (other 1300 lines).

Overview
--------

Sync Mail Dir uses `ssh` to transmit and receive data, and to run commands
on the remote host (but in principle it could use any bi-directional
channel, like `nc` for example).

Sync Mail Dir needs to be installed on both hosts: we call server the host
we push to and pull from, we call client the host we push from and pull to.
In the most common scenario, the server is our mail server, while the
client is our laptop.

The directory `~/.smd/` contains the configuration file(s), some `fifo` needed
to short-circuit the software running on the client and on the server, and
a cache file (called db-file from now on) that represents the status of the
mailbox last time we successfully pushed.  The configuration file is needed
only on the client host (the one that will run `smd-pull` and `smd-push`).

Sync Mail Dir is a layered set of tools, where low level tools are
implemented in low level languages (to achieve decent performances) and
high level tools are written in scripting languages (to achieve better
flexibility).

- [`mddiff`](mddiff.1.txt) 
  is a small and hopefully efficient C program that given a
  db-file (a snapshot of a previous mailbox status) generates a set of
  actions (a diff) a client should perform to synchronize its local mailbox
  copy.  It is a low level tool, not meant to be used directly by the user.
- [`smd-server`](smd-server.1.txt)
  a simple script that calls `mddiff` to compute the diff,
  sends it to the client and then listens for client requests like getting a
  mail body or header.  Even if this tool is simple to run, redirecting its
  input and output to `smd-client` over a network may not be straightforward,
  thus users should not call it directly.
- [`smd-client`](smd-client.1.txt) 
  a quite complex script applying a diff locally, eventually
  requesting data to the server.  In case the diff cannot be applied
  cleanly, it outputs an error message that higher level tools should display
  to the user.  As `smd-server` it is a quite high level tool, but should not
  be called directly by the average user.
- [`smd-pull`](smd-pull.1.txt) 
  thanks to ssh, it executes `smd-server` on the server host and
  `smd-client` on the client host.  This allows to pull remote changes and
  apply them locally.  The remote mailbox is left untouched.  This tool is
  meant to be called by the user.
- [`smd-push`](smd-push.1.txt) 
  thanks to ssh, it executes `smd-client` on the server host and
  `smd-serer` on the client host.  This allows to push local changes and to
  apply them on the remote host.  The local mailbox is left untouched.  This
  tool is meant to be called by the user.
- [`smd-translate`](smd-translate.1.txt) 
  handles common folder renaming scenarios. The tool 
  is meant to be used as a translator program in the configuration file 
  of `smd-pull` and `smd-push`.
- [`smd-check-conf`](smd-check-conf.1.txt) 
  performs a quick check that a setup, especially when it involves
  some folders renaming, actually works as expected. This tool is meant to
  be manually called by the user to check a given configuration file.
- [`smd-restricted-shell`](smd-restricted-shell.1.txt)
  only meant to be used in conjunction with an SSH key and specifically in
  the remote OpenSSH's authorized_keys file to restrict the commands allowed.
- [`smd-uniform-names`](smd-uniform-names.1.txt)
  meant to be used before the first synchronization, when the content of
  the local and remote mailboxes is similar, but mails are named differently.
  This is often the case when migrating from offlineimap, that encodes
  some metadata in the local file names.
- [`smd-loop`](smd-loop.1.txt) 
  runs runs smd-push and smd-pull at regular intervals as defined
  by the user in a configuration file, in the style of a crontab, but
  catches recoverable errors (like a, non recurrent, network problem),
  bailing out only in cases where human intervention is needed.  This is
  the utility you may want to run if you are using a textual environment or
  a graphical one not based on GNOME.
- [`smd-applet`](smd-applet.1.txt) 
  is an applet for the GNOME notification area, that runs
  `smd-loop`, eventually notifying the user for critical events and allowing
  him to solve them by clicking on buttons instead of running commands from
  the shell.

HOW-TO
------

Four end-user tools are provided.  You need to configure them bottom-up,
starting from the simpler ones (`smd-pull` and `smd-push`), that already
allow to synchronize two mailboxes.  Anyway it is recommended to use
higher level tools like `smd-loop` or `smd-applet`.

### smd-push and smd-pull

- `smd-pull [name]` to obtain the changes made on the remote mailbox applied
  locally
- `smd-push [name]` vice versa

Both tools read a configuration file in `~/.smd/config.name`, that is a simple
shell script sourced by both when called with argument `name`.  If no argument
is given, they source `~/.smd/config.default`. 
This file defines the following variables (see the [`smd-config`](smd-config.5.txt) manpage for a complete documentation):

- `SERVERNAME` is a valid alias for ssh.  It should be defined in
  your `~/.ssh/config`, with compression enabled.  For example:

        Host smd-server-foo
          BatchMode yes
          Compression yes
          Hostname your.real.server.name
          User you

- `CLIENTNAME` a name for your client: the host name concatenated with
   the server name should be fine.  Note that you can pull and push from
   different hosts, and each of them needs a unique CLIENTNAME in its
   configuration file.

- `MAILBOX` a list of roots to be synchronized.  There is no support for
  name mapping, thus they should be named the same on the remote host.
  Maildirs will be searched starting from these roots, traversing
  subdirectories recursively.

- `DEBUG` can be set to true to log the traffic between client and server

The first time you run `smd-pull` or `smd-push` a template file will be
generated for you.

The first synchronization can take a while, since all mail messages have to be
inspected and their hash recorded in the db-file.  While it is not strictly
needed, you may want to copy a huge mailbox (hundreds of megabytes) to the
other endpoint by hand (for example zipping it with a slow but space efficient
compressor like `bzip2` and `lzma`) to save some bandwidth.  `smd` is not
optimized for such a (uncommon) situation: it uses regular ssh stream
compression to transfer mails, that can be way less space efficient than
running a compression utility over the whole mailbox.  Moreover, you should
not edit your mailboxes during the first synchronization, since edits may
force the software to bail out without saving the db-file, and thus making
the following run as slow as the first one.

To check your setup you can run the `smd-check-conf` utility.

The tools `smd-push` and `smd-push` can be run with the `-d`
or `--dry-run` flag. In this way they will not modify in any way any maildir.
Nevertheless it can be very handy to understand which changes smd would 
perform if not told otherwise.

### smd-loop

`smd-loop` runs `smd-push` and `smd-pull` at regular intervals as defined
by the user in the `~/.smd/loop` configuration file.  On errors that
are reported to be transient, its retries a second time before failing.

The first time you run `smd-loop` a sample config file is created for you.
The configuration file is line oriented.  Each line is composed of three space
separated fields:

- `pull-frequency`
- `push-frequency`
- `endpoint-name`

Frequencies are expressed in minutes, while endpoint
name is a valid name for `smd-pull` and `smd-push`.  Lines
beginning with # are considered as comments.  The following example
calls the command `smd-pull default` every 3 minutes, and `smd-push default`
every 10.

    # pull-frequency push-frequency endpoint-name
      3              10             default

### smd-applet

smd-applet just runs `smd-loop`, notifying the user if errors occur.  It
can be run with `--configure` to pop-up its configuration window, that
allows to tune its notification behaviour and to edit the configuration
files for `smd-loop` and `smd-push/pull`.

Notes on performances
---------------------

On my core duo 2 laptop equipped with a 5400rpm hard drive and with an hot
cache, copying a 150MB mailbox with `tar cf - Mail | ssh -C localhost tar
xf -` takes 17 seconds.  Doing the same with `smd-pull` takes 19 seconds.
This is clearly an uncommon workload, since you rarely get 150MB of new
mails, but it shows the extra work the tool is doing (like computing
`sha1` sums for every mail, or the client-server protocol overhead) makes
`smd` not so inefficient.  Once the mailbox has been copied, running
`smd-pull` again to check for updates is almost instantaneous.
As of September 2011, my mailbox is 1.3G and is on average pulled/pushed in 
less than 2s using a regular ADSL connection.

Advanced Usage
==============

### restricted remote shell

Version `1.2.3` comes with `smd-restricted-shell` to improve security,
especially when using password-less SSH keys.  This tool takes
advantage of the OpenSSH command= option, which permits to restrict
the command that is allowed to be executed on the remote host when the
login is performed using a particular SSH key.

Once you have identified in the ~/.ssh/authorized_keys on the remote
host the SSH key you use together with Sync Mail Dir, prepend the line
as in the following example:

    command="/usr/bin/smd-restricted-shell" ssh-rsa AAAABBBBCCCC....

### multiple servers

From verion `0.9.4` multiple configuration files are supported.  This means
you can push/pull from/to different remote mailboxes (one at a time).  This
turned out to be useful when migrating a mailbox:

    smd-pull oldserver
    smd-push newserver

Note that you can run this for a while, not just one time.  This can make the
transition from a mail-address to another smooth, since simply forwarding mail
from the old to the new one makes you believe you changed the subscription to
all your mailing lists, that is obviously not always the case since nobody
remembers all the mailing lists he is subscribed to.

### hooks

From version 0.9.14, `smd-push` and `smd-pull` can run user defined
hooks before and after doing their job.  Hooks are regular programs (usually
shell scripts) placed in the following directories:

- `~/.smd/hooks/pre-push.d/`
- `~/.smd/hooks/pre-pull.d/`
- `~/.smd/hooks/post-push.d/`
- `~/.smd/hooks/post-pull.d/`

Hooks receive four arguments in the following order:

1. when: `pre` or `post`
2. what: `push` or `pull`
3. endpoint: the endpoint name, usually `default`
4. status: the current status, `0` for OK, `1` for error.
   pre-hooks always receive `0`, post hooks receive the value
   `smd-push/pull` will return after the hooks terminate

Hooks should not fail, if they do so then `smd-push/pull` will fail too.
Sample hooks are available in the source tarball under `sample-hooks/`.
Some documentation about [available hooks](sample-hooks/) is also present.

### folder renaming

In case your local and remote mailbox names or sub-folders structure differ,
smd version 1.2.0 offers a translation functionality.

The configuration file must be changed, replacing `MAILBOX` with
`MAILBOX_LOCAL` and `MAILBOX_REMOTE`.  Moreover two translator
programs must be defined: 

- `TRANSLATOR_RL` to translate remote names to local ones
- `TRANSLATOR_LR` to translate local names to remote ones

To avoid common mistakes in writing translators, some recurrent renaming
scenarios are handled by the `smd-translate` utility. Please refer to
[`smd-translate`](smd-translate.1.txt) manpage. What following describes 
how to write a translator by hand, that may be necessary is your translation
schema is no supported by `smd-translate`.

A translator is a program that receives in standard input one or more
folder names,
and must print on standard output a corresponding folder name
on success, or prints the string `ERROR` followed by a new line
and an optional following error message otherwise end exists returning 1.
Note that the folder names will be complete of the `MAILBOX_LOCAL` or
`MAILBOX_REMOTE` part and will always terminate with `cur`, `new` or `tmp`.
For example, consider the following configuration file:

    MAILBOX_LOCAL=Mail
    MAILBOX_REMOTE=Maildir
    TRANSLATOR_LR=loc_to_remote.sh
    TRANSLATOR_RL=remote_to_loc.sh

When `smd-pull` is called, `remote_to_loc.sh` is called to translate names
like `Maildir/cur` or `Maildir/.sub.folder/new` to local names like
`Mail/cur` or `Mail/sub.folder/new`. An example of `remote_to_loc.sh`
could be:

    #!/bin/sh
    sed --unbuffered -e 's/^Maildir\(.*\)$/Mail\1/' -e 's?/\.?/?'

Note the `--unbuffered`: translators should not work in buffered mode.
I.e. when given a line in input (terminated by `\n`) they must output a
line without expecting any additional input.

Translating the way back is trickier, since the leading `.` must be
added only to sub-folders:

    #!/bin/sh
    t() {
        if [ "$1" = Mail/cur -o "$1" = Mail/tmp -o "$1" = Mail/new ]; then
            echo $1 | sed --unbuffered 's?^Mail/\(.*\)?Maildir/\1?'
        else
            echo $1 | sed --unbuffered 's?^Mail/\(.*\)?Maildir/.\1?'
        fi
    }
    while read M; do t "$M"; done

Last, translators are executed as external programs, thus they must be
present in your path (for example in `~/bin/`) and have the executable
bit set (`chmod +x`).

To check your setup you can run the `smd-check-conf` utility.
The test consists in listing local and remote mailboxes, calling
the translators, displaying the result to the user and checking for
round trip (i.e. that the translators programs behave as inverse
functions on the current input).

You can also test your setup using the dry-run mode with 
`smd-push -d` and `smd-pull -d` and examine their output. 
This anyway should be tried before the first pull/push, and thus 
may take a long time depending on the size of your mailboxes.

To avoid common mistakes in writing translators, some recurrent renaming
scenarios are handled by the `smd-translate` utility. 
Assuming the `MAILBOX_LOCAL` configuration variable is set to `Mail`
and the `MAILBOX_REMOTE` is set to `Maildir`, 
One can use the following configuration file snippet as a reference,
where default must be repaced with the endpoint name:
  
    TRANSLATOR_RL="smd-translate -m oimap-dovecot -d RL default"
    TRANSLATOR_LR="smd-translate -m oimap-dovecot -d LR default"

### excluding paths

In case some paths need to be skipped, they can be specified as
space separated glob(7) expressions in the following variable

    EXCLUDE="Mail/Spam Mail/Trash"

Note that these glob expressions have to match real paths, no translation
operation is applied to them, so it may be necessary to specify different
expressions for the local and remote endpoint.  In that case the following
variables can be used:

    EXCLUDE_LOCAL
    EXCLUDE_REMOTE

Matching is performed using fnmatch(3) with no special flags, thus '`*`' and
'`?`' match any character including '`/`'. Note that spaces in glob
expressions must be replaced by `%20`. For example, to exclude all
paths matching the expression '`Mail/delayed [1-5] days/*`' the variable
EXCLUDE must be set to '`Mail/delayed%20[1-5]%20days/*`'.
Last, matching is performed every time a directory is entered, and if
the matching succeeds the derectory and all its subdirectories are skipped.
Thus there is no need to specify a trailing '`/*`' in every expression.

### local synchronization

If the remote and local mailboxes are on the same filesystem, one has
to specify the `-l` option to `smd-client`. This option can be specified
adding to the configuration file `SMDCLIENTOPTS=-l` and set 
`SERVERNAME=localhost`. 

### avoid deletions 

In some cases, usually unidirectional synchronizations, one may want
to not propagate deletions. E.g. one keeps a slim working mailbox but
pushes to a backup mailbox to save every email. For that scenario
smd-pull and smd-push accept a -n, --no-delete, option. 
To avoid specifying this option every time one can put it in the
configuration file:

    SMDSERVEROPTS=-n

### migration from offlineimap

Migrating from offlineimap may require an extra step, since the local and
remote mailboxes may not only differ in their names and sub folders, but also
in the names of the single mail messages. Indeed offlineimap encodes some
metadata in the file names local to the client. The `smd-translate` utility
translates only folder names and not messages names.

To uniform the names used on the client to the ones used on the server you can
do as follows:

1. Remove `X-OfflineIMAP` from every mail that contains it.
   Often the same email has that extra header line on the server but not on
   the client. A not so dirty way of achieving that is the following snippet:
   `find Mail -type f -exec sed -i '/^X-OfflineIMAP/d' {} \;`

2. Run the `smd-uniform-names` utility.
   This utility has to be run before the first synchronization, but after smd
   is configured and `smd-check-conf` has reported no errors.
   `smd-uniform-names` does not modify the mailbox, but instead it generates a
   shell script that you can run to perform the renaming.

Installation
============

Syncmaildir is part of the Debian archive.  If you are running Debian or one of
its derivatives, you can install the `syncmaildir` and `syncmaildir-applet`
packages with your favourite package manager.

If you want to install it from source you need a C compiler, the development
files for GLib, GNU make and sed.  For `smd-applet` you also need the Vala
compiler, libgee, GTK+ 3, libnotify and dbus-glib.  You may also want to
customize few variables in the `Makefile`.  Then typing `make && make install`
should be enough to have syncmaildir installed.  Some known platforms are
supported by templates defined at the end of `Makefile`, for example you may
want to run `make osx/text/all && make osx/text/install` to properly build and
install text mode only syncmaildir utilities on an MacOSX platform.

Runtime dependencies are: `ssh`, `xdelta`, `lua5.1` and `bash`.

Design
======

The design of the software is detailed in the [design document](DESIGN.md).
If you are interested in hacking `smd`, it may be helpful.

Download
========

The software can be download from the Source Forge
[download page](https://github.com/gares/syncmaildir/releases)

Author
======

The software is distributed as-is, with no warranties, so if your mailbox
is irremediably lost due to Sync Mail Dir, you will get nothing back, but
you can complain with me, of course.  If you find the software useful,
an happy-user report is also welcome.

