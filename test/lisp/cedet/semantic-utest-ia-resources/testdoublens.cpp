// testdoublens.cpp --- semantic-ia-utest completion engine unit tests

// Copyright (C) 2008-2025 Free Software Foundation, Inc.

// Author: Eric M. Ludlam <zappo@gnu.org>

// This file is part of GNU Emacs.

// GNU Emacs is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// GNU Emacs is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

#include "testdoublens.hpp"

namespace Name1 {
  namespace Name2 {

    Foo::Foo()
    {
      p// -1-
	// #1# ( "pMumble" "publishStuff" )
	;
    }

    int Foo::get() // ^1^
    {
      p// -2-
	// #2# ( "pMumble" "publishStuff" )
	;
      return 0;
    }

    void Foo::publishStuff(int a, int b) // ^2^
    {
      int foo = a;
      int bar = b;
    }

    // Test polymorphism on arg types.  Note that order is
    // mixed to maximize failure cases
    void Foo::publishStuff(char a, char b) // ^4^
    {
      int foo = a;
      int bar = b;
    }

    void Foo::sendStuff(int a, int b) // ^3^
    {
      int foo = a;
      int bar = b;

      Foo::publishStuff(1,2)

    }

  } // namespace Name2
} // namespace Name1

// Test multiple levels of metatype expansion
int test_fcn () {
  stage3_Foo MyFoo;

  MyFoo.// -3-
    // #3# ( "Mumble" "get" )
    ;

  Name1::Name2::F//-4-
    // #4# ( "Foo" )
    ;

  // @TODO - get this working...
  Name1::stage2_Foo::M//-5-
    /// #5# ( "Mumble" )
    ;
}

stage3_Foo foo_fcn() {
  // Can we go "up" to foo with senator-go-to-up-reference?
}


// Second test from Ravikiran Rajagopal

namespace A {
  class foo {
  public:
    void aa();
    void bb();
  };
}
namespace A {
  class bar {
  public:
    void xx();
  public:
    foo myFoo;
  };

  void bar::xx()
  {
    myFoo.// -6- <--- cursor is here after the dot
      // #6# ( "aa" "bb" )
      ;
  }
}

// Double namespace example from Hannu Koivisto
//
// This is tricky because the parent class "Foo" is found within the
// scope of B, so the scope calculation needs to put that together
// before searching for parents in scope.
namespace a {
  namespace b {

    class Bar : public Foo
    {
      int baz();
    };

    int Bar::baz()
    {
      return dum// -7-
	// #7# ( "dumdum" )
	;
    }

  } // namespace b
} // namespace a

// Three namespace example from Hannu Koivisto
//
// This one is special in that the name e::Foo, where "e" is in
// the scope, and not referenced from the global namespace.  This
// wasn't previously handled, so the fullscope needed to be added
// to the list of things searched when in split-name decent search mode
// for scopes.

namespace d {
  namespace e {

    class Foo
    {
    public:
      int write();
    };

  } // namespace d
} // namespace e


namespace d {
  namespace f {

    class Bar
    {
    public:
      int baz();

    private:
      e::Foo &foo;
    };

    int Bar::baz()
    {
      return foo.w// -8-
	// #8# ( "write" )
	;
    }

  } // namespace f
} // namespace d

// Fully qualified const struct function arguments
class ContainsStruct
{
  struct TheStruct
  {
    int memberOne;
    int memberTwo;
  };
};

void someFunc(const struct ContainsStruct::TheStruct *foo)
{
  foo->// -9-
    // #9# ("memberOne" "memberTwo")
}

// Class with structure tag
class ContainsNamedStruct
{
  struct _fooStruct
  {
    int memberOne;
    int memberTwo;
  } member;
};

void someOtherFunc(void)
{
  ContainsNamedStruct *someClass;
  // This has to find ContainsNamedStruct::_fooStruct
  someClass->member.// -10-
    // #10# ("memberOne" "memberTwo")
}
