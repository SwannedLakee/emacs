;; -*- mode: lisp-data; -*-

((~eof 60 EOF))
((~ping 60 "PING " (group (+ (in "0-9"))))
 (0 "PONG " cookie))

((nick 10 "NICK tester"))
((user 10 "USER user 0 * :tester")
 (0 ":irc.foonet.org 001 tester :Welcome to the foonet IRC Network tester")
 (0 ":irc.foonet.org 002 tester :Your host is irc.foonet.org, running version oragono-2.6.0-7481bf0385b95b16")
 (0 ":irc.foonet.org 003 tester :This server was created Tue, 04 May 2021 05:06:18 UTC")
 (0 ":irc.foonet.org 004 tester irc.foonet.org oragono-2.6.0-7481bf0385b95b16 BERTZios CEIMRUabefhiklmnoqstuv Iabefhkloqv")
 (0 ":irc.foonet.org 005 tester AWAYLEN=390 BOT=B CASEMAPPING=ascii CHANLIMIT=#:100 CHANMODES=Ibe,k,fl,CEMRUimnstu CHANNELLEN=64 CHANTYPES=# ELIST=U EXCEPTS EXTBAN=,m FORWARD=f INVEX KICKLEN=390 :are supported by this server")
 (0 ":irc.foonet.org 005 tester MAXLIST=beI:60 MAXTARGETS=4 MODES MONITOR=100 NETWORK=FooNet NICKLEN=32 PREFIX=(qaohv)~&@%+ STATUSMSG=~&@%+ TARGMAX=NAMES:1,LIST:1,KICK:1,WHOIS:1,USERHOST:10,PRIVMSG:4,TAGMSG:4,NOTICE:4,MONITOR:100 TOPICLEN=390 UTF8MAPPING=rfc8265 UTF8ONLY WHOX :are supported by this server")
 (0 ":irc.foonet.org 005 tester draft/CHATHISTORY=100 :are supported by this server")
 (0 ":irc.foonet.org 251 tester :There are 0 users and 3 invisible on 1 server(s)")
 (0 ":irc.foonet.org 252 tester 0 :IRC Operators online")
 (0 ":irc.foonet.org 253 tester 0 :unregistered connections")
 (0 ":irc.foonet.org 254 tester 1 :channels formed")
 (0 ":irc.foonet.org 255 tester :I have 3 clients and 0 servers")
 (0 ":irc.foonet.org 265 tester 3 3 :Current local users 3, max 3")
 (0 ":irc.foonet.org 266 tester 3 3 :Current global users 3, max 3")
 (0 ":irc.foonet.org 422 tester :MOTD File is missing"))

((mode-user 10 "MODE tester +i")
 (0 ":irc.foonet.org 221 tester +i")
 (0 ":irc.foonet.org NOTICE tester :This server is in debug mode and is logging all user I/O. If you do not wish for everything you send to be readable by the server owner(s), please disconnect."))

((drop 0 DROP))
