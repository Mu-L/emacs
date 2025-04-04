# alloca.m4
# serial 21
dnl Copyright (C) 2002-2004, 2006-2007, 2009-2025 Free Software Foundation,
dnl Inc.
dnl This file is free software; the Free Software Foundation
dnl gives unlimited permission to copy and/or distribute it,
dnl with or without modifications, as long as this notice is preserved.
dnl This file is offered as-is, without any warranty.

AC_DEFUN([gl_FUNC_ALLOCA],
[
  AC_REQUIRE([AC_FUNC_ALLOCA])
  if test $ac_cv_func_alloca_works = no; then
    gl_PREREQ_ALLOCA
  fi

  # Define an additional variable used in the Makefile substitution.
  if test $ac_cv_working_alloca_h = yes; then
    AC_CACHE_CHECK([for alloca as a compiler built-in], [gl_cv_rpl_alloca], [
      AC_EGREP_CPP([Need own alloca], [
#if defined __GNUC__ || defined _AIX || defined _MSC_VER
        Need own alloca
#endif
        ], [gl_cv_rpl_alloca=yes], [gl_cv_rpl_alloca=no])
    ])
    if test $gl_cv_rpl_alloca = yes; then
      dnl OK, alloca can be implemented through a compiler built-in.
      AC_DEFINE([HAVE_ALLOCA], [1],
        [Define to 1 if you have 'alloca' after including <alloca.h>,
         a header that may be supplied by this distribution.])
      GL_GENERATE_ALLOCA_H=true
    else
      dnl alloca exists as a library function, i.e. it is slow and probably
      dnl a memory leak. Don't define HAVE_ALLOCA in this case.
      GL_GENERATE_ALLOCA_H=false
    fi
  else
    GL_GENERATE_ALLOCA_H=true
  fi

  if test $ac_cv_working_alloca_h = yes; then
    HAVE_ALLOCA_H=1
  else
    HAVE_ALLOCA_H=0
  fi
  AC_SUBST([HAVE_ALLOCA_H])
])

# Prerequisites of lib/alloca.c.
# STACK_DIRECTION is already handled by AC_FUNC_ALLOCA.
AC_DEFUN([gl_PREREQ_ALLOCA], [:])

m4_version_prereq([2.70], [], [

# This works around a bug in autoconf <= 2.68 and has simplifications
# from 2.70.  See:
# https://lists.gnu.org/r/bug-gnulib/2011-06/msg00277.html
# https://git.savannah.gnu.org/cgit/autoconf.git/commit/?id=6cd9f12520b0d6f76d3230d7565feba1ecf29497
# https://git.savannah.gnu.org/cgit/autoconf.git/commit/?id=15edf7fd8094fd14a89d9891dd72a9624762597a

# _AC_LIBOBJ_ALLOCA
# -----------------
# Set up the LIBOBJ replacement of 'alloca'.  Well, not exactly
# AC_LIBOBJ since we actually set the output variable 'ALLOCA'.
# Nevertheless, for Automake, AC_LIBSOURCES it.
m4_define([_AC_LIBOBJ_ALLOCA],
[# The SVR3 libPW and SVR4 libucb both contain incompatible functions
# that cause trouble.  Some versions do not even contain alloca or
# contain a buggy version.  If you still want to use their alloca,
# use ar to extract alloca.o from them instead of compiling alloca.c.
AC_LIBSOURCES(alloca.c)
AC_SUBST([ALLOCA], [\${LIBOBJDIR}alloca.$ac_objext])dnl
AC_DEFINE(C_ALLOCA, 1, [Define to 1 if using 'alloca.c'.])

AC_CACHE_CHECK([stack direction for C alloca],
               [ac_cv_c_stack_direction],
[AC_RUN_IFELSE([AC_LANG_SOURCE(
[AC_INCLUDES_DEFAULT
int
find_stack_direction (int *addr, int depth)
{
  int dir, dummy = 0;
  if (! addr)
    addr = &dummy;
  *addr = addr < &dummy ? 1 : addr == &dummy ? 0 : -1;
  dir = depth ? find_stack_direction (addr, depth - 1) : 0;
  return dir + dummy;
}

int
main (int argc, char **argv)
{
  return find_stack_direction (0, argc + !argv + 20) < 0;
}])],
               [ac_cv_c_stack_direction=1],
               [ac_cv_c_stack_direction=-1],
               [ac_cv_c_stack_direction=0])])
AH_VERBATIM([STACK_DIRECTION],
[/* If using the C implementation of alloca, define if you know the
   direction of stack growth for your system; otherwise it will be
   automatically deduced at runtime.
        STACK_DIRECTION > 0 => grows toward higher addresses
        STACK_DIRECTION < 0 => grows toward lower addresses
        STACK_DIRECTION = 0 => direction of growth unknown */
#undef STACK_DIRECTION])dnl
AC_DEFINE_UNQUOTED(STACK_DIRECTION, $ac_cv_c_stack_direction)
])# _AC_LIBOBJ_ALLOCA
])
