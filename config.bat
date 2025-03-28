@echo off
rem   ----------------------------------------------------------------------
rem   Configuration script for MSDOS
rem   Copyright (C) 1994-1999, 2001-2025 Free Software Foundation, Inc.

rem   This file is part of GNU Emacs.

rem   GNU Emacs is free software: you can redistribute it and/or modify
rem   it under the terms of the GNU General Public License as published by
rem   the Free Software Foundation, either version 3 of the License, or
rem   (at your option) any later version.

rem   GNU Emacs is distributed in the hope that it will be useful,
rem   but WITHOUT ANY WARRANTY; without even the implied warranty of
rem   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
rem   GNU General Public License for more details.

rem   You should have received a copy of the GNU General Public License
rem   along with GNU Emacs.  If not, see https://www.gnu.org/licenses/.

rem   ----------------------------------------------------------------------
rem   YOU'LL NEED THE FOLLOWING UTILITIES TO MAKE EMACS:
rem
rem   + msdos version 3 or better.
rem   + DJGPP version 2.02 or later (version 2.03 or later recommended).
rem   + make utility that allows breaking of the 128 chars limit on
rem     command lines.  ndmake (as of version 4.5) won't work due to a
rem     line length limit.  The DJGPP port of make works (and is
rem     recommended).
rem   + rm, mv, and cp (from GNU file utilities).
rem   + sed (you can use the port that comes with DJGPP).
rem
rem   You should be able to get all the above utilities from the DJGPP FTP
rem   site, ftp.delorie.com, in the directory "pub/djgpp/current/v2gnu".
rem   ----------------------------------------------------------------------
set X11=
set nodebug=
set djgpp_ver=
set sys_malloc=
set libxml=
if "%1" == "" goto usage
rem   ----------------------------------------------------------------------
rem   See if their environment is large enough.  We need 28 bytes.
set $foo$=789012345678901234567
if not "%$foo$%" == "789012345678901234567" goto SmallEnv
set $foo$=
:again
if "%1" == "" goto usage
if "%1" == "--with-x" goto withx
if "%1" == "--no-debug" goto nodebug
if "%1" == "msdos" goto msdos
if "%1" == "--with-system-malloc" goto sysmalloc
:usage
echo Usage: config [--no-debug] [--with-system-malloc] [--with-x] msdos
echo [Read the script before you run it.]
goto end
rem   ----------------------------------------------------------------------
:withx
set X11=Y
shift
goto again
rem   ----------------------------------------------------------------------
:nodebug
set nodebug=Y
shift
goto again
rem   ----------------------------------------------------------------------
:sysmalloc
set sys_malloc=Y
shift
goto again
rem   ----------------------------------------------------------------------
:msdos
Echo Checking whether 'sed' is available...
sed -e "w junk.$$$" <Nul
If Exist junk.$$$ Goto sedOk
Echo To configure 'Emacs' you need to have 'sed'!
Goto End
:sedOk
Echo Checking whether 'rm' is available...
rm -f junk.$$$
If Not Exist junk.$$$ Goto rmOk
Echo To configure 'Emacs' you need to have 'rm'!
Goto End
:rmOk
Echo Checking whether 'mv' is available...
rm -f junk.1 junk.2
echo foo >junk.1
mv junk.1 ./junk.2
If Exist junk.2 Goto mvOk
Echo To configure 'Emacs' you need to have 'mv'!
rm -f junk.1
Goto End
:mvOk
rm -f junk.2
Echo Checking whether 'gcc' is available...
echo int main(void){} >junk.c
gcc -c junk.c
if exist junk.o goto gccOk
Echo To configure 'Emacs' you need to have 'gcc'!
rm -f junk.c
Goto End
:gccOk
rm -f junk.c junk.o junk junk.exe
Echo Checking what version of DJGPP is installed...
If Not "%DJGPP%" == "" goto djgppOk
Echo To compile 'Emacs' under MS-DOS you MUST have DJGPP installed!
Goto End
:djgppOk
echo #include "sys/version.h" >junk.c
echo int main()          >>junk.c
echo #ifdef __DJGPP__    >>junk.c
echo {return (__DJGPP__)*10 + (__DJGPP_MINOR__);} >>junk.c
echo #else               >>junk.c
echo #ifdef __GO32__     >>junk.c
echo {return 10;}         >>junk.c
echo #else               >>junk.c
echo {return 0;}         >>junk.c
echo #endif              >>junk.c
echo #endif              >>junk.c
gcc -o junk junk.c
if not exist junk.exe coff2exe junk
junk
If ErrorLevel 10 Goto go32Ok
rm -f junk.c junk junk.exe
Echo To compile 'Emacs' under MS-DOS you MUST have DJGPP installed!
Goto End
:go32Ok
set djgpp_ver=2
If Not ErrorLevel 22 Echo To build 'Emacs' you need DJGPP v2.02 or later!
If Not ErrorLevel 22 Goto End
rm -f junk.c junk junk.exe
rem DJECHO is used by the top-level Makefile in the v2.x build
Echo Checking whether 'djecho' is available...
redir -o Nul -eo djecho -o junk.$$$ foo
If Exist junk.$$$ Goto djechoOk
Echo To build 'Emacs' you need the 'djecho.exe' program!
Echo 'djecho.exe' is part of 'djdevNNN.zip' basic DJGPP development kit.
Echo Either unpack 'djecho.exe' from the 'djdevNNN.zip' archive,
Echo or, if you have 'echo.exe', copy it to 'djecho.exe'.
Echo Then run CONFIG.BAT again with the same arguments you did now.
Goto End
:djechoOk
rm -f junk.$$$
Echo Configuring for DJGPP Version %DJGPP_VER% ...
Rem   ----------------------------------------------------------------------
Echo Configuring the source directory...
cd src

rem   Create "epaths.h"
sed -f ../msdos/sed4.inp <epaths.in >epaths.tmp
update epaths.tmp epaths.h >nul
rm -f epaths.tmp

rem   Create "config.h"
rm -f config.h2 config.tmp
if exist config.in sed -e '' config.in > config.tmp
if exist ..\msdos\autogen\config.in sed -e '' ../msdos/autogen/config.in > config.tmp
if "%X11%" == "" goto src4
if exist config.in sed -f ../msdos/sed2x.inp < config.in > config.tmp
if exist ..\msdos\autogen\config.in sed -f ../msdos/sed2x.inp < ..\msdos\autogen\config.in > config.tmp
:src4
sed -f ../msdos/sed2v2.inp <config.tmp >config.h2
Rem See if they have libxml2 later than v2.2.0 installed
Echo Checking whether libxml2 v2.2.1 or later is installed ...
rm -f junk.c junk.o junk junk.exe
rem Use djecho here because we need to quote brackets
djecho "#include <libxml/xmlversion.h>"             >junk.c
djecho "int main()"                                 >>junk.c
djecho "{return (LIBXML_VERSION > 20200 ? 0 : 1);}" >>junk.c
redir -o Nul -eo gcc -I/dev/env/DJDIR/include/libxml2 -o junk junk.c
if not exist junk Goto xmlDone
if not exist junk.exe coff2exe junk
junk
If ErrorLevel 1 Goto xmlDone
Echo Configuring with libxml2 ...
sed -e "/#undef HAVE_LIBXML2/s/^.*$/#define HAVE_LIBXML2 1/" <config.h2 >config.h3
sed -e "/#define EMACS_CONFIG_FEATURES/s/^.*$/#define EMACS_CONFIG_FEATURES \"LIBXML2\"/" <config.h3 >config.h2
set libxml=1
:xmlDone
rm -f junk.c junk junk.exe
Rem See if they requested a SYSTEM_MALLOC build
if "%sys_malloc%" == "" Goto cfgDone
rm -f config.tmp
ren config.h2 config.tmp
sed -f ../msdos/sedalloc.inp <config.tmp >config.h2

:cfgDone
rm -f junk.c junk junk.exe
update config.h2 config.h >nul
rm -f config.tmp config.h2

rem   Create "makefile" from "makefile.in".
rm -f Makefile makefile.tmp
copy Makefile.in+deps.mk makefile.tmp
sed -f ../msdos/sed1v2.inp <makefile.tmp >Makefile
rm -f makefile.tmp

if "%X11%" == "" goto src5
mv Makefile makefile.tmp
sed -f ../msdos/sed1x.inp <makefile.tmp >Makefile
rm -f makefile.tmp
:src5

if "%sys_malloc%" == "" goto src5a
sed -e "/^GMALLOC_OBJ *=/s/gmalloc.o//" <Makefile >makefile.tmp
sed -e "/^VMLIMIT_OBJ *=/s/vm-limit.o//" <makefile.tmp >makefile.tmp2
sed -e "/^RALLOC_OBJ *=/s/ralloc.o//" <makefile.tmp2 >Makefile
rm -f makefile.tmp makefile.tmp2
:src5a

if "%nodebug%" == "" goto src6
sed -e "/^CFLAGS *=/s/ *-gcoff//" <Makefile >makefile.tmp
sed -e "/^LDFLAGS *=/s/=/=-s/" <makefile.tmp >Makefile
rm -f makefile.tmp
:src6

if "%libxml%" == "" goto src7
sed -e "/^LIBXML2_LIBS *=/s/=/= -lxml2 -lz -liconv/" <Makefile >makefile.tmp
sed -e "/^LIBXML2_CFLAGS *=/s|=|= -I/dev/env/DJDIR/include/libxml2|" <makefile.tmp >Makefile
rm -f makefile.tmp
:src7
Rem Create .d files for new files in src/
If Not Exist deps\stamp mkdir deps
for %%f in (*.c) do @call ..\msdos\depfiles.bat %%f
echo deps-stamp > deps\stamp
cd ..
rem   ----------------------------------------------------------------------
Echo Configuring the library source directory...
cd lib-src
sed -f ../msdos/sed3v2.inp <Makefile.in >Makefile
mv Makefile makefile.tmp
sed -n -e "/^AC_INIT/s/[^,]*, \([^,]*\).*/@set emver=\1/p" ../configure.ac > emver.bat
call emver.bat
sed -e "s/@version@/%emver%/g" <makefile.tmp >Makefile
if "%X11%" == "" goto libsrc2a
mv Makefile makefile.tmp
sed -f ../msdos/sed3x.inp <makefile.tmp >Makefile
rm -f makefile.tmp
:libsrc2a
if "%nodebug%" == "" goto libsrc3
sed -e "/^CFLAGS *=/s/ *-gcoff//" <Makefile >makefile.tmp
sed -e "/^ALL_CFLAGS *=/s/=/= -s/" <makefile.tmp >Makefile
rm -f makefile.tmp
:libsrc3
cd ..
rem   ----------------------------------------------------------------------
if "%X11%" == "" goto oldx1
Echo Configuring the oldxmenu directory...
cd oldxmenu
sed -f ../msdos/sed5x.inp <Makefile.in >Makefile
if "%nodebug%" == "" goto oldx2
sed -e "/^CFLAGS *=/s/ *-gcoff//" <Makefile >makefile.tmp
mv -f makefile.tmp Makefile
:oldx2
cd ..
:oldx1
rem   ----------------------------------------------------------------------
Echo Configuring the doc directory, expect one "File not found" message...
cd doc
Rem Rename files like djtar on plain DOS filesystem would.
If Exist emacs\emacsver.texi.in update emacs/emacsver.texi.in emacs/emacsver.in
If Exist man\emacs.1.in update man/emacs.1.in man/emacs.in
If Exist ..\etc\refcards\emacsver.tex.in update ../etc/refcards/emacsver.tex.in ../etc/refcards/emacsver.in
Rem The two variants for lispintro below is for when the shell
Rem supports long file names but DJGPP does not
for %%d in (emacs lispref lispintro lispintr misc) do sed -e "s/@version@/%emver%/g" -f ../msdos/sed6.inp < %%d\Makefile.in > %%d\Makefile
Rem produce emacs.1 from emacs.in
If Exist man\emacs.1 goto manOk
sed -e "s/@version@/%emver%/g" -e "s/@PACKAGE_BUGREPORT@/bug-gnu-emacs@gnu.org/g" < man\emacs.in > man\emacs.1
:manOk
cd ..
rem   ----------------------------------------------------------------------
Echo Configuring the lib directory...
If Exist build-aux\snippet\c++defs.h update build-aux/snippet/c++defs.h build-aux/snippet/cxxdefs.h
cd lib
Rem Rename files like djtar on plain DOS filesystem would.
If Exist c++defs.h update c++defs.h cxxdefs.h
If Exist alloca.in.h update alloca.in.h alloca.in-h
If Exist assert.in.h update assert.in.h assert.in-h
If Exist byteswap.in.h update byteswap.in.h byteswap.in-h
If Exist dirent.in.h update dirent.in.h dirent.in-h
If Exist errno.in.h update errno.in.h errno.in-h
If Exist endian.in.h update endian.in.h endian.in-h
If Exist execinfo.in.h update execinfo.in.h execinfo.in-h
If Exist fcntl.in.h update fcntl.in.h fcntl.in-h
If Exist getopt.in.h update getopt.in.h getopt.in-h
If Exist getopt-cdefs.in.h update getopt-cdefs.in.h getopt-cdefs.in-h
If Exist ieee754.in.h update ieee754.in.h ieee754.in-h
If Exist inttypes.in.h update inttypes.in.h inttypes.in-h
If Exist limits.in.h update limits.in.h limits.in-h
If Exist signal.in.h update signal.in.h signal.in-h
If Exist signal.in.h update signal.in.h signal.in-h
If Exist stdalign.in.h update stdalign.in.h stdalign.in-h
If Exist stddef.in.h update stddef.in.h  stddef.in-h
If Exist stdint.in.h update stdint.in.h  stdint.in-h
If Exist stdio.in.h update stdio.in.h stdio.in-h
If Exist stdlib.in.h update stdlib.in.h stdlib.in-h
If Exist string.in.h update string.in.h string.in-h
If Exist sys_random.in.h update sys_random.in.h sys_random.in-h
If Exist sys_select.in.h update sys_select.in.h sys_select.in-h
If Exist sys_stat.in.h update sys_stat.in.h sys_stat.in-h
If Exist sys_time.in.h update sys_time.in.h sys_time.in-h
If Exist sys_types.in.h update sys_types.in.h sys_types.in-h
If Exist time.in.h update time.in.h time.in-h
If Exist unistd.in.h update unistd.in.h unistd.in-h
If Exist stdckdint.in.h update stdckdint.in.h stdckdint.in-h
If Exist stdbit.in.h update stdbit.in.h stdbit.in-h
If Exist gnulib.mk.in update gnulib.mk.in gnulib.mk-in
Rem Only repository has the msdos/autogen directory
If Exist Makefile.in sed -f ../msdos/sedlibcf.inp < Makefile.in > makefile.tmp
If Exist ..\msdos\autogen\Makefile.in sed -f ../msdos/sedlibcf.inp < ..\msdos\autogen\Makefile.in > makefile.tmp
sed -f ../msdos/sedlibmk.inp < makefile.tmp > Makefile
rm -f makefile.tmp
sed -f ../msdos/sedlibcf.inp < gnulib.mk-in > gnulib.tmp
sed -f ../msdos/sedlibmk.inp < gnulib.tmp > gnulib.mk
rm -f gnulib.tmp
Rem Create directories in lib/ that MKDIR_P is supposed to create
Rem but I have no idea how to do that on MS-DOS.
mkdir sys
Rem Create .d files for new files in lib/ and lib/malloc/
If Not Exist deps\stamp mkdir deps
for %%f in (*.c) do @call ..\msdos\depfiles.bat %%f
echo deps-stamp > deps\stamp
If Not Exist deps\malloc\stamp mkdir deps\malloc
for %%f in (malloc\*.c) do @call ..\msdos\depfiles.bat %%f
echo deps-stamp > deps\malloc\stamp
cd ..
rem   ----------------------------------------------------------------------
Echo Configuring the lisp directory...
cd lisp
If Exist gnus\.dir-locals.el update gnus/.dir-locals.el gnus/_dir-locals.el
sed -f ../msdos/sedlisp.inp < Makefile.in > Makefile
cd ..
rem   ----------------------------------------------------------------------
Echo Configuring the leim directory...
cd leim
sed -f ../msdos/sedleim.inp < Makefile.in > Makefile
cd ..
rem   ----------------------------------------------------------------------
If Not Exist admin\unidata goto noadmin
Echo Configuring the admin/unidata directory...
cd admin\unidata
sed -f ../../msdos/sedadmin.inp < Makefile.in > Makefile
Echo Configuring the admin/charsets directory...
cd ..\charsets
sed -f ../../msdos/sedadmin.inp < Makefile.in > Makefile
Echo Configuring the admin/grammars directory...
cd ..\grammars
sed -f ../../msdos/sedadmin.inp < Makefile.in > Makefile
cd ..\..
:noadmin
rem   ----------------------------------------------------------------------
Echo Configuring the main directory...
If Exist .dir-locals.el update .dir-locals.el _dir-locals.el
If Exist src\.dbxinit update src/.dbxinit src/_dbxinit
Echo Looking for the GDB init file...
If Exist src\.gdbinit update src/.gdbinit src/_gdbinit
If Exist src\_gdbinit goto gdbinitOk
Echo ERROR:
Echo I cannot find the GDB init file.  It was called ".gdbinit" in
Echo the Emacs distribution, but was probably renamed to some other
Echo name without the leading dot when you untarred the archive.
Echo It should be in the "src/" subdirectory.  Please make sure this
Echo file exists and is called "_gdbinit" with a leading underscore.
Echo Then run CONFIG.BAT again with the same arguments you did now.
goto End
:gdbinitOk
Echo Looking for the GDB init file...found
rem GNUMakefile is not appropriate for MS-DOS so move it out of the way
If Exist GNUmakefile mv -f GNUmakefile GNUmakefile.unix
copy msdos\mainmake.v2 Makefile >nul
rem   ----------------------------------------------------------------------
goto End
:SmallEnv
echo Your environment size is too small.  Please enlarge it and run me again.
echo For example, type "command.com /e:2048" to have 2048 bytes available.
set $foo$=
:end
set X11=
set nodebug=
set djgpp_ver=
set sys_malloc=
set libxml=
set emver=
