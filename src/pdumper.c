/* Copyright (C) 2018-2025 Free Software Foundation, Inc.

This file is part of GNU Emacs.

GNU Emacs is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

GNU Emacs is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.  */

#include <config.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "blockinput.h"
#include "buffer.h"
#include "charset.h"
#include "coding.h"
#include "fingerprint.h"
#include "frame.h"
#include "intervals.h"
#include "lisp.h"
#include "pdumper.h"
#include "window.h"
#include "sysstdio.h"
#include "systime.h"
#include "thread.h"
#include "bignum.h"
#include "treesit.h"

#ifdef CHECK_STRUCTS
# include "dmpstruct.h"
#endif

/*
  TODO:

  - Two-pass dumping: first assemble object list, then write all.
    This way, we can perform arbitrary reordering or maybe use fancy
    graph algorithms to get better locality.

  - Don't emit relocations that happen to set Emacs memory locations
    to values they will already have.

  - Nullify frame_and_buffer_state.

  - Preferred base address for relocation-free non-PIC startup.

  - Compressed dump support.

*/

#ifdef HAVE_PDUMPER

#if GNUC_PREREQ (4, 7, 0)
# pragma GCC diagnostic error "-Wshadow"
#endif

#define VM_POSIX 1
#define VM_MS_WINDOWS 2

#if !USE_LSB_TAG && !defined WIDE_EMACS_INT
# define VM_SUPPORTED 0
#elif defined (HAVE_MMAP) && defined (MAP_FIXED)
# define VM_SUPPORTED VM_POSIX
# if !defined (MAP_POPULATE) && defined (MAP_PREFAULT_READ)
#  define MAP_POPULATE MAP_PREFAULT_READ
# elif !defined (MAP_POPULATE)
#  define MAP_POPULATE 0
# endif
#elif defined (WINDOWSNT)
  /* Use a float infinity, to avoid compiler warnings in comparing vs
     candidates' score.  */
# undef INFINITY
# define INFINITY __builtin_inff ()
# include <windows.h>
# define VM_SUPPORTED VM_MS_WINDOWS
#else
# define VM_SUPPORTED 0
#endif

/* Require an architecture in which pointers, ptrdiff_t and intptr_t
   are the same size and have the same layout, and where bytes have
   eight bits --- that is, a general-purpose computer made after 1990.
   Also require Lisp_Object to be at least as wide as pointers.  */
static_assert (sizeof (ptrdiff_t) == sizeof (void *));
static_assert (sizeof (intptr_t) == sizeof (ptrdiff_t));
static_assert (sizeof (void (*) (void)) == sizeof (void *));
static_assert (sizeof (ptrdiff_t) <= sizeof (Lisp_Object));
static_assert (sizeof (ptrdiff_t) <= sizeof (EMACS_INT));

static size_t
divide_round_up (size_t x, size_t y)
{
  return (x + y - 1) / y;
}

static const char dump_magic[16] = {
  'D', 'U', 'M', 'P', 'E', 'D',
  'G', 'N', 'U',
  'E', 'M', 'A', 'C', 'S'
};

static pdumper_hook dump_hooks[24];
static int nr_dump_hooks = 0;

static pdumper_hook dump_late_hooks[24];
static int nr_dump_late_hooks = 0;

static struct
{
  void *mem;
  int sz;
} remembered_data[32];
static int nr_remembered_data = 0;

typedef int_least32_t dump_off;
#define DUMP_OFF_MIN INT_LEAST32_MIN
#define DUMP_OFF_MAX INT_LEAST32_MAX
#define DUMP_OFF_WIDTH INT_LEAST32_WIDTH
#define PRIdDUMP_OFF PRIdLEAST32

enum { EMACS_INT_XDIGITS = (EMACS_INT_WIDTH + 3) / 4 };

static void ATTRIBUTE_FORMAT_PRINTF (1, 2)
dump_trace (const char *fmt, ...)
{
  if (0)
    {
      va_list args;
      va_start (args, fmt);
      vfprintf (stderr, fmt, args);
      va_end (args);
    }
}

static ssize_t dump_read_all (int fd, void *buf, size_t bytes_to_read);

static dump_off
ptrdiff_t_to_dump_off (ptrdiff_t value)
{
  eassert (DUMP_OFF_MIN <= value);
  eassert (value <= DUMP_OFF_MAX);
  return (dump_off) value;
}

/* Worst-case allocation granularity on any system that might load
   this dump.  */
static int
dump_get_max_page_size (void)
{
  return 64 * 1024;
}

#define dump_offsetof(type, member)                             \
  (ptrdiff_t_to_dump_off (offsetof (type, member)))

enum dump_reloc_type
  {
    /* dump_ptr = dump_ptr + emacs_basis()  */
    RELOC_DUMP_TO_EMACS_PTR_RAW,
    /* dump_ptr = dump_ptr + dump_base  */
    RELOC_DUMP_TO_DUMP_PTR_RAW,
    /* dump_mpz = [rebuild bignum]  */
    RELOC_NATIVE_COMP_UNIT,
    RELOC_NATIVE_SUBR,
    RELOC_BIGNUM,
    /* dump_lv = make_lisp_ptr (dump_lv + dump_base,
				type - RELOC_DUMP_TO_DUMP_LV)
       (Special case for symbols: make_lisp_symbol)
       Must be second-last.  */
    RELOC_DUMP_TO_DUMP_LV,
    /* dump_lv = make_lisp_ptr (dump_lv + emacs_basis(),
				type - RELOC_DUMP_TO_DUMP_LV)
       (Special case for symbols: make_lisp_symbol.)
       Must be last.  */
    RELOC_DUMP_TO_EMACS_LV = RELOC_DUMP_TO_DUMP_LV + 8,
  };

enum emacs_reloc_type
  {
    /* Copy raw bytes from the dump into Emacs.  The length field in
       the emacs_reloc is the number of bytes to copy.  */
    RELOC_EMACS_COPY_FROM_DUMP,
    /* Set a piece of memory in Emacs to a value we store directly in
       this relocation.  The length field contains the number of bytes
       we actually copy into Emacs.  */
    RELOC_EMACS_IMMEDIATE,
    /* Set an aligned pointer-sized object in Emacs to a pointer into
       the loaded dump at the given offset.  The length field is
       always the machine word size.  */
    RELOC_EMACS_DUMP_PTR_RAW,
    /* Set an aligned pointer-sized object in Emacs to point to
       something also in Emacs.  The length field is always
       the machine word size.  */
    RELOC_EMACS_EMACS_PTR_RAW,
    /* Set an aligned Lisp_Object in Emacs to point to a value in the
       dump.  The length field is the _tag type_ of the Lisp_Object,
       not a byte count!  */
    RELOC_EMACS_DUMP_LV,
    /* Set an aligned Lisp_Object in Emacs to point to a value in the
       Emacs image.  The length field is the _tag type_ of the
       Lisp_Object, not a byte count!  */
    RELOC_EMACS_EMACS_LV,
  };

enum
  {
   EMACS_RELOC_TYPE_BITS = 3,
   EMACS_RELOC_LENGTH_BITS = DUMP_OFF_WIDTH - EMACS_RELOC_TYPE_BITS
  };

static_assert (RELOC_EMACS_EMACS_LV <= (1 << EMACS_RELOC_TYPE_BITS));

struct emacs_reloc
{
  ENUM_BF (emacs_reloc_type) type : EMACS_RELOC_TYPE_BITS;
  dump_off length : EMACS_RELOC_LENGTH_BITS;
  dump_off emacs_offset;
  union
  {
    dump_off dump_offset;
    dump_off emacs_offset2;
    intmax_t immediate;
  } u;
};

/* Set the type of an Emacs relocation.

   Also make sure that the type fits in the bitfield.  */
static void
emacs_reloc_set_type (struct emacs_reloc *reloc,
                      enum emacs_reloc_type type)
{
  reloc->type = type;
  eassert (reloc->type == type);
}

struct dump_table_locator
{
  /* Offset in dump, in bytes, of the first entry in the dump
     table.  */
  dump_off offset;
  /* Number of entries in the dump table.  We need an explicit end
     indicator (as opposed to a special sentinel) so we can efficiently
     binary search over the relocation entries.  */
  dump_off nr_entries;
};

enum
  {
   DUMP_RELOC_TYPE_BITS = 5,
   DUMP_RELOC_ALIGNMENT_BITS = 2,

   /* Minimum alignment required by dump file format.  */
   DUMP_RELOCATION_ALIGNMENT = 1 << DUMP_RELOC_ALIGNMENT_BITS,

   /* The alignment granularity (in bytes) for objects we store in the
      dump.  Always suitable for heap objects; may be more aligned.  */
   DUMP_ALIGNMENT = max (GCALIGNMENT, DUMP_RELOCATION_ALIGNMENT),

   DUMP_RELOC_OFFSET_BITS = DUMP_OFF_WIDTH - DUMP_RELOC_TYPE_BITS
  };

static_assert (RELOC_DUMP_TO_EMACS_LV + 8 < (1 << DUMP_RELOC_TYPE_BITS));
static_assert (DUMP_ALIGNMENT >= GCALIGNMENT);

struct dump_reloc
{
  unsigned int raw_offset : DUMP_RELOC_OFFSET_BITS;
  ENUM_BF (dump_reloc_type) type : DUMP_RELOC_TYPE_BITS;
};
static_assert (sizeof (struct dump_reloc) == sizeof (dump_off));

/* Set the type of a dump relocation.

   Also assert that the type fits in the bitfield.  */
static void
dump_reloc_set_type (struct dump_reloc *reloc, enum dump_reloc_type type)
{
  reloc->type = type;
  eassert (reloc->type == type);
}

static dump_off
dump_reloc_get_offset (struct dump_reloc reloc)
{
  return reloc.raw_offset << DUMP_RELOC_ALIGNMENT_BITS;
}

static void
dump_reloc_set_offset (struct dump_reloc *reloc, dump_off offset)
{
  eassert (offset >= 0);
  reloc->raw_offset = offset >> DUMP_RELOC_ALIGNMENT_BITS;
  if (dump_reloc_get_offset (*reloc) != offset)
    error ("dump relocation out of range");
}

void
dump_fingerprint (FILE *output, char const *label,
		  unsigned char const xfingerprint[sizeof fingerprint])
{
  enum { hexbuf_size = 2 * sizeof fingerprint };
  char hexbuf[hexbuf_size];
  hexbuf_digest (hexbuf, xfingerprint, sizeof fingerprint);
  fprintf (output, "%s%s%.*s\n", label, *label ? ": " : "",
	   hexbuf_size, hexbuf);
}

/* To be used if some order in the relocation process has to be enforced. */
enum reloc_phase
  {
    /* First to run.  Place every relocation with no dependency here.  */
    EARLY_RELOCS,
    /* Late and very late relocs are relocated at the very last after
       all hooks has been run.  All lisp machinery is at disposal
       (memory allocation allowed too).  */
    LATE_RELOCS,
    VERY_LATE_RELOCS,
    /* Fake, must be last.  */
    RELOC_NUM_PHASES
  };

/* Format of an Emacs dump file.  All offsets are relative to
   the beginning of the file.  An Emacs dump file is coupled
   to exactly the Emacs binary that produced it, so details of
   alignment and endianness are unimportant.

   An Emacs dump file contains the contents of the Lisp heap.
   On startup, Emacs can start faster by mapping a dump file into
   memory and using the objects contained inside it instead of
   performing initialization from scratch.

   The dump file can be loaded at arbitrary locations in memory, so it
   includes a table of relocations that let Emacs adjust the pointers
   embedded in the dump file to account for the location where it was
   actually loaded.

   Dump files can contain pointers to other objects in the dump file
   or to parts of the Emacs binary.  */
struct dump_header
{
  /* File type magic.  */
  char magic[sizeof (dump_magic)];

  /* Associated Emacs binary.  */
  unsigned char fingerprint[sizeof fingerprint];

  /* Relocation table for the dump file; each entry is a
     struct dump_reloc.  */
  struct dump_table_locator dump_relocs[RELOC_NUM_PHASES];

  /* "Relocation" table we abuse to hold information about the
     location and type of each lisp object in the dump.  We need for
     pdumper_object_type and ultimately for conservative GC
     correctness.  */
  struct dump_table_locator object_starts;

  /* Relocation table for Emacs; each entry is a struct
     emacs_reloc.  */
  struct dump_table_locator emacs_relocs;

  /* Start of sub-region of hot region that we can discard after load
     completes.  The discardable region ends at cold_start.

     This region contains objects that we copy into the Emacs image at
     dump-load time.  */
  dump_off discardable_start;

  /* Start of the region that does not require relocations and that we
     expect never to be modified.  This region can be memory-mapped
     directly from the backing dump file with the reasonable
     expectation of taking few copy-on-write faults.

     For correctness, however, this region must be modifible, since in
     rare cases it is possible to see modifications to these bytes.
     For example, this region contains string data, and it's
     technically possible for someone to ASET a string character
     (although nobody tends to do that).

     The start of the cold region is always aligned on a page
     boundary.  */
  dump_off cold_start;

  /* Offset of a vector of the dumped hash tables.  */
  dump_off hash_list;
};

/* Double-ended singly linked list.  */
struct dump_tailq
{
  Lisp_Object head;
  Lisp_Object tail;
  intptr_t length;
};

/* Queue of objects to dump.  */
struct dump_queue
{
  /* Objects with no link weights at all.  Kept in dump order.  */
  struct dump_tailq zero_weight_objects;
  /* Objects with simple link weight: just one entry of type
     WEIGHT_NORMAL.  Score in this special case is non-decreasing as
     position increases, so we can avoid the need to rescan a big list
     for each object by storing these objects in order.  */
  struct dump_tailq one_weight_normal_objects;
  /* Likewise, for objects with one WEIGHT_STRONG weight.  */
  struct dump_tailq one_weight_strong_objects;
  /* List of objects with complex link weights --- i.e., not one of
     the above cases.  Order is irrelevant, since we scan the whole
     list every time.  Relatively few objects end up here.  */
  struct dump_tailq fancy_weight_objects;
  /* Hash table of link weights: maps an object to a list of zero or
     more (BASIS . WEIGHT) pairs.  As a special case, an object with
     zero weight is marked by Qt in the hash table --- this way, we
     can distinguish objects we've seen but that have no weight from
     ones that we haven't seen at all.  */
  Lisp_Object link_weights;
  /* Hash table mapping object to a sequence number --- used to
     resolve ties.  */
  Lisp_Object sequence_numbers;
  dump_off next_sequence_number;
};

enum cold_op
  {
    COLD_OP_OBJECT,
    COLD_OP_STRING,
    COLD_OP_CHARSET,
    COLD_OP_BUFFER,
    COLD_OP_BIGNUM,
#ifdef HAVE_NATIVE_COMP
    COLD_OP_NATIVE_SUBR,
#endif
  };

/* This structure controls what operations we perform inside
   dump_object.  */
struct dump_flags
{
  /* Actually write object contents to the dump.  Without this flag
     set, we still scan objects and enqueue pointed-to objects; making
     this flag false is useful when we want to process an object's
     referents normally, but dump an object itself separately,
     later.  */
  bool_bf dump_object_contents : 1;
  /* Record object starts. We turn this flag off when writing to the
     discardable section so that we don't trick conservative GC into
     thinking we have objects there.  Ignored (we never record object
     starts) if dump_object_contents is false.  */
  bool_bf record_object_starts : 1;
  /* Pack objects tighter than GC memory alignment would normally
     require.  Useful for objects copied into the Emacs image instead
     of used directly from the loaded dump.
  */
  bool_bf pack_objects : 1;
  /* Sometimes we dump objects that we've already scanned for outbound
     references to other objects.  These objects should not cause new
     objects to enter the object dumping queue.  This flag causes Emacs
     to assert that no new objects are enqueued while dumping.  */
  bool_bf assert_already_seen : 1;
  /* Punt on unstable hash tables: defer them to ctx->deferred_hash_tables.  */
  bool_bf defer_hash_tables : 1;
  /* Punt on symbols: defer them to ctx->deferred_symbols.  */
  bool_bf defer_symbols : 1;
  /* Punt on cold objects: defer them to ctx->cold_queue.  */
  bool_bf defer_cold_objects : 1;
  /* Punt on copied objects: defer them to ctx->copied_queue.  */
  bool_bf defer_copied_objects : 1;
};

/* Information we use while we dump.  Note that we're not the garbage
   collector and can operate under looser constraints: specifically,
   we allocate memory during the dumping process.  */
struct dump_context
{
  /* Header we'll write to the dump file when done.  */
  struct dump_header header;
  /* Data that will be written to the dump file.  */
  void *buf;
  dump_off buf_size;
  dump_off max_offset;

  Lisp_Object old_purify_flag;
  Lisp_Object old_post_gc_hook;
  Lisp_Object old_process_environment;

#ifdef REL_ALLOC
  bool blocked_ralloc;
#endif

  /* File descriptor for dumpfile; < 0 if closed.  */
  int fd;
  /* Name of dump file --- used for error reporting.  */
  Lisp_Object dump_filename;
  /* Current offset in dump file.  */
  dump_off offset;

  /* Starting offset of current object.  */
  dump_off obj_offset;

  /* Flags currently in effect for dumping.  */
  struct dump_flags flags;

  dump_off end_heap;

  /* Hash mapping objects we've already dumped to their offsets.  */
  Lisp_Object objects_dumped;

  /* Hash mapping objects to where we got them.  Used for debugging.  */
  Lisp_Object referrers;
  Lisp_Object current_referrer;
  bool have_current_referrer;

  /* Queue of objects to dump.  */
  struct dump_queue dump_queue;

  /* Deferred object lists.  */
  Lisp_Object deferred_hash_tables;
  Lisp_Object deferred_symbols;

  /* Fixups in the dump file.  */
  Lisp_Object fixups;

  /* Hash table of staticpro values: avoids double relocations.  */
  Lisp_Object staticpro_table;

  /* Hash table mapping symbols to their pre-copy-queue fwd or blv
     structures (which we dump immediately before the start of the
     discardable section). */
  Lisp_Object symbol_aux;
  /* Queue of copied objects for special treatment.  */
  Lisp_Object copied_queue;
  /* Queue of cold objects to dump.  */
  Lisp_Object cold_queue;

  /* Relocations in the dump.  */
  Lisp_Object dump_relocs[RELOC_NUM_PHASES];

  /* Object starts.  */
  Lisp_Object object_starts;

  /* Relocations in Emacs.  */
  Lisp_Object emacs_relocs;

  /* Hash table mapping bignums to their _data_ blobs, which we store
     in the cold section.  The actual Lisp_Bignum objects are normal
     heap objects.  */
  Lisp_Object bignum_data;

  /* List of hash tables that have been dumped.  */
  Lisp_Object hash_tables;

  dump_off number_hot_relocations;
  dump_off number_discardable_relocations;
};

/* These special values for use as offsets in dump_remember_object and
   dump_recall_object indicate that the corresponding object isn't in
   the dump yet (and so it has no valid offset), but that it's on one
   of our to-be-dumped-later object queues (or that we haven't seen it
   at all).  All values must be non-positive, since positive values
   are physical dump offsets.  */
enum dump_object_special_offset
  {
   DUMP_OBJECT_IS_RUNTIME_MAGIC = -6,
   DUMP_OBJECT_ON_COPIED_QUEUE = -5,
   DUMP_OBJECT_ON_HASH_TABLE_QUEUE = -4,
   DUMP_OBJECT_ON_SYMBOL_QUEUE = -3,
   DUMP_OBJECT_ON_COLD_QUEUE = -2,
   DUMP_OBJECT_ON_NORMAL_QUEUE = -1,
   DUMP_OBJECT_NOT_SEEN = 0,
  };

/* Weights for score scores for object non-locality.  */

struct link_weight
{
  /* Wrapped in a struct to break unwanted implicit conversion.  */
  int value;
};

static struct link_weight const
  WEIGHT_NONE = { .value = 0 },
  WEIGHT_NORMAL = { .value = 1000 },
  WEIGHT_STRONG = { .value = 1200 };


/* Dump file creation */

static void dump_grow_buffer (struct dump_context *ctx)
{
  ctx->buf = xrealloc (ctx->buf, ctx->buf_size = (ctx->buf_size ?
						  (ctx->buf_size * 2)
						  : 8 * 1024 * 1024));
}

static dump_off dump_object (struct dump_context *ctx, Lisp_Object object);
static dump_off dump_object_for_offset (struct dump_context *ctx,
					Lisp_Object object);

/* Like the Lisp function `push'.  Return NEWELT.  */
static Lisp_Object
dump_push (Lisp_Object *where, Lisp_Object newelt)
{
  *where = Fcons (newelt, *where);
  return newelt;
}

/* Like the Lisp function `pop'.  */
static Lisp_Object
dump_pop (Lisp_Object *where)
{
  Lisp_Object ret = XCAR (*where);
  *where = XCDR (*where);
  return ret;
}

static bool
dump_tracking_referrers_p (struct dump_context *ctx)
{
  return !NILP (ctx->referrers);
}

static void
dump_set_have_current_referrer (struct dump_context *ctx, bool have)
{
#ifdef ENABLE_CHECKING
  ctx->have_current_referrer = have;
#endif
}

/* Return true if objects should be enqueued in CTX to refer to an
   object that the caller should store into CTX->current_referrer.

   Until dump_clear_referrer is called, any objects enqueued are being
   enqueued because the object refers to them.  It is not valid to
   enqueue objects without a referrer set.  We check this constraint
   at runtime.

   It is invalid to call dump_set_referrer twice without an
   intervening call to dump_clear_referrer.  */
static bool
dump_set_referrer (struct dump_context *ctx)
{
  eassert (!ctx->have_current_referrer);
  dump_set_have_current_referrer (ctx, true);
  return dump_tracking_referrers_p (ctx);
}

/* Unset the referrer that dump_set_referrer prepared for.  */
static void
dump_clear_referrer (struct dump_context *ctx)
{
  eassert (ctx->have_current_referrer);
  dump_set_have_current_referrer (ctx, false);
  if (dump_tracking_referrers_p (ctx))
    ctx->current_referrer = Qnil;
}

static Lisp_Object
dump_ptr_referrer (const char *label, void const *address)
{
  char buf[128];
  if (sizeof buf <= snprintf (buf, sizeof buf, "%s @ %p", label, address))
    strcpy (buf + sizeof buf - 4, "...");
  return build_string (buf);
}

static void
print_paths_to_root (struct dump_context *ctx, Lisp_Object object);

static void dump_remember_cold_op (struct dump_context *ctx,
                                   enum cold_op op,
                                   Lisp_Object arg);

static AVOID
error_unsupported_dump_object (struct dump_context *ctx,
                               Lisp_Object object,
			       const char *msg)
{
  if (dump_tracking_referrers_p (ctx))
    print_paths_to_root (ctx, object);
  error ("unsupported object type in dump: %s", msg);
}

static uintptr_t
emacs_basis (void)
{
  return (uintptr_t) &Vpurify_flag;
}

static void *
emacs_ptr_at (const ptrdiff_t offset)
{
  /* TODO: assert somehow that the result is actually in the Emacs
     image.  */
  return (void *) (emacs_basis () + offset);
}

static dump_off
emacs_offset (const void *emacs_ptr)
{
  /* TODO: assert that EMACS_PTR is actually in the Emacs image.  */
  eassert (emacs_ptr != NULL);
  intptr_t emacs_ptr_value = (intptr_t) emacs_ptr;
  ptrdiff_t emacs_ptr_relative = emacs_ptr_value - (intptr_t) emacs_basis ();
  return ptrdiff_t_to_dump_off (emacs_ptr_relative);
}

/* Return whether OBJECT is a symbol the storage of which is built into
   Emacs (and hence is implicitly offset from an address in the Emacs
   image).  */

static bool
dump_builtin_symbol_p (Lisp_Object object)
{
  /* Symbols with position cannot be dumped, but not returning true for
     them avoids producing references to unrelocated Lisp_Objects in
     fixup processing or depending on the value of
     symbols_with_pos_enabled.  */
  return BARE_SYMBOL_P (object) && c_symbol_p (XSYMBOL (object));
}

/* Return whether OBJECT has the same bit pattern in all Emacs
   invocations --- i.e., is invariant across a dump.  Note that some
   self-representing objects still need to be dumped!
*/
static bool
dump_object_self_representing_p (Lisp_Object object)
{
  return FIXNUMP (object) || dump_builtin_symbol_p (object);
}

static intmax_t
intmax_t_from_lisp (Lisp_Object value)
{
  intmax_t n;
  bool ok = integer_to_intmax (value, &n);
  eassert (ok);
  return n;
}

static Lisp_Object
intmax_t_to_lisp (intmax_t value)
{
  return INT_TO_INTEGER (value);
}

static dump_off
dump_off_from_lisp (Lisp_Object value)
{
  intmax_t n = intmax_t_from_lisp (value);
  eassert (DUMP_OFF_MIN <= n && n <= DUMP_OFF_MAX);
  return n;
}

static Lisp_Object
dump_off_to_lisp (dump_off value)
{
  return INT_TO_INTEGER (value);
}

static void
dump_write (struct dump_context *ctx, const void *buf, dump_off nbyte)
{
  eassert (nbyte == 0 || buf != NULL);
  eassert (ctx->obj_offset == 0);
  eassert (ctx->flags.dump_object_contents);
  while (ctx->offset + nbyte > ctx->buf_size)
    dump_grow_buffer (ctx);
  memcpy ((char *)ctx->buf + ctx->offset, buf, nbyte);
  ctx->offset += nbyte;
}

static Lisp_Object
make_eq_hash_table (void)
{
  return CALLN (Fmake_hash_table, QCtest, Qeq);
}

static void
dump_tailq_init (struct dump_tailq *tailq)
{
  tailq->head = tailq->tail = Qnil;
  tailq->length = 0;
}

static intptr_t
dump_tailq_length (const struct dump_tailq *tailq)
{
  return tailq->length;
}

static void
dump_tailq_prepend (struct dump_tailq *tailq, Lisp_Object value)
{
  Lisp_Object link = Fcons (value, tailq->head);
  tailq->head = link;
  if (NILP (tailq->tail))
    tailq->tail = link;
  tailq->length += 1;
}

static bool
dump_tailq_empty_p (struct dump_tailq *tailq)
{
  return NILP (tailq->head);
}

static Lisp_Object
dump_tailq_peek (struct dump_tailq *tailq)
{
  eassert (!dump_tailq_empty_p (tailq));
  return XCAR (tailq->head);
}

static Lisp_Object
dump_tailq_pop (struct dump_tailq *tailq)
{
  eassert (!dump_tailq_empty_p (tailq));
  eassert (tailq->length > 0);
  tailq->length -= 1;
  Lisp_Object value = XCAR (tailq->head);
  tailq->head = XCDR (tailq->head);
  if (NILP (tailq->head))
    tailq->tail = Qnil;
  return value;
}

static void
dump_seek (struct dump_context *ctx, dump_off offset)
{
  if (ctx->max_offset < ctx->offset)
    ctx->max_offset = ctx->offset;
  eassert (ctx->obj_offset == 0);
  ctx->offset = offset;
}

static void
dump_write_zero (struct dump_context *ctx, dump_off nbytes)
{
  while (nbytes > 0)
    {
      uintmax_t zero = 0;
      dump_off to_write = sizeof (zero);
      if (to_write > nbytes)
        to_write = nbytes;
      dump_write (ctx, &zero, to_write);
      nbytes -= to_write;
    }
}

static void
dump_align_output (struct dump_context *ctx, int alignment)
{
  if (ctx->offset % alignment != 0)
    dump_write_zero (ctx, alignment - (ctx->offset % alignment));
}

static dump_off
dump_object_start (struct dump_context *ctx,
                   void *out,
                   dump_off outsz)
{
  /* We dump only one object at a time, so obj_offset should be
     invalid on entry to this function.  */
  eassert (ctx->obj_offset == 0);
  int alignment = ctx->flags.pack_objects ? 1 : DUMP_ALIGNMENT;
  if (ctx->flags.dump_object_contents)
    dump_align_output (ctx, alignment);
  ctx->obj_offset = ctx->offset;
  memset (out, 0, outsz);
  return ctx->offset;
}

static dump_off
dump_object_finish (struct dump_context *ctx,
                    const void *out,
                    dump_off sz)
{
  dump_off offset = ctx->obj_offset;
  eassert (offset > 0);
  eassert (offset == ctx->offset); /* No intervening writes.  */
  ctx->obj_offset = 0;
  if (ctx->flags.dump_object_contents)
    dump_write (ctx, out, sz);
  return offset;
}

/* Return offset at which OBJECT has been dumped, or one of the dump_object_special_offset
   negative values, or DUMP_OBJECT_NOT_SEEN.  */
static dump_off
dump_recall_object (struct dump_context *ctx, Lisp_Object object)
{
  Lisp_Object dumped = ctx->objects_dumped;
  return dump_off_from_lisp (Fgethash (object, dumped,
                                       make_fixnum (DUMP_OBJECT_NOT_SEEN)));
}

static void
dump_remember_object (struct dump_context *ctx,
                      Lisp_Object object,
                      dump_off offset)
{
  Fputhash (object,
            dump_off_to_lisp (offset),
            ctx->objects_dumped);
}

static void
dump_note_reachable (struct dump_context *ctx, Lisp_Object object)
{
  eassert (ctx->have_current_referrer);
  if (!dump_tracking_referrers_p (ctx))
    return;
  Lisp_Object referrer = ctx->current_referrer;
  Lisp_Object obj_referrers = Fgethash (object, ctx->referrers, Qnil);
  if (NILP (Fmemq (referrer, obj_referrers)))
    Fputhash (object, Fcons (referrer, obj_referrers), ctx->referrers);
}

/* If this object lives in the Emacs image and not on the heap, return
   a pointer to the object data.  Otherwise, return NULL.  */
static void *
dump_object_emacs_ptr (Lisp_Object lv)
{
  if (SUBRP (lv) && !NATIVE_COMP_FUNCTIONP (lv))
    return XSUBR (lv);
  if (dump_builtin_symbol_p (lv))
    return XSYMBOL (lv);
  if (XTYPE (lv) == Lisp_Vectorlike
      && PSEUDOVECTOR_TYPEP (&XVECTOR (lv)->header, PVEC_THREAD)
      && main_thread_p (XTHREAD (lv)))
    return XTHREAD (lv);
  return NULL;
}

static void
dump_queue_init (struct dump_queue *dump_queue)
{
  dump_tailq_init (&dump_queue->zero_weight_objects);
  dump_tailq_init (&dump_queue->one_weight_normal_objects);
  dump_tailq_init (&dump_queue->one_weight_strong_objects);
  dump_tailq_init (&dump_queue->fancy_weight_objects);
  dump_queue->link_weights = make_eq_hash_table ();
  dump_queue->sequence_numbers = make_eq_hash_table ();
  dump_queue->next_sequence_number = 1;
}

static bool
dump_queue_empty_p (struct dump_queue *dump_queue)
{
  ptrdiff_t count = XHASH_TABLE (dump_queue->sequence_numbers)->count;
  bool is_empty = count == 0;
  eassert (count == XFIXNAT (Fhash_table_count (dump_queue->link_weights)));
  if (!is_empty)
    {
      eassert (!dump_tailq_empty_p (&dump_queue->zero_weight_objects)
	       || !dump_tailq_empty_p (&dump_queue->one_weight_normal_objects)
	       || !dump_tailq_empty_p (&dump_queue->one_weight_strong_objects)
	       || !dump_tailq_empty_p (&dump_queue->fancy_weight_objects));
    }
  else
    {
      /* If we're empty, we can still have a few stragglers on one of
         the above queues.  */
    }

  return is_empty;
}

static void
dump_queue_push_weight (Lisp_Object *weight_list,
                        dump_off basis,
                        struct link_weight weight)
{
  if (EQ (*weight_list, Qt))
    *weight_list = Qnil;
  dump_push (weight_list, Fcons (dump_off_to_lisp (basis),
                                 dump_off_to_lisp (weight.value)));
}

static void
dump_queue_enqueue (struct dump_queue *dump_queue,
                    Lisp_Object object,
                    dump_off basis,
                    struct link_weight weight)
{
  Lisp_Object weights = Fgethash (object, dump_queue->link_weights, Qnil);
  Lisp_Object orig_weights = weights;
  /* N.B. want to find the last item of a given weight in each queue
     due to prepend use.  */
  bool use_single_queues = true;
  if (NILP (weights))
    {
      /* Object is new.  */
      EMACS_UINT uobj = XLI (object);
      dump_trace ("new object %0*"pI"x weight=%d\n", EMACS_INT_XDIGITS, uobj,
		  weight.value);

      if (weight.value == WEIGHT_NONE.value)
        {
          eassert (weight.value == 0);
          dump_tailq_prepend (&dump_queue->zero_weight_objects, object);
          weights = Qt;
        }
      else if (!use_single_queues)
        {
          dump_tailq_prepend (&dump_queue->fancy_weight_objects, object);
          dump_queue_push_weight (&weights, basis, weight);
        }
      else if (weight.value == WEIGHT_NORMAL.value)
        {
          dump_tailq_prepend (&dump_queue->one_weight_normal_objects, object);
          dump_queue_push_weight (&weights, basis, weight);
        }
      else if (weight.value == WEIGHT_STRONG.value)
        {
          dump_tailq_prepend (&dump_queue->one_weight_strong_objects, object);
          dump_queue_push_weight (&weights, basis, weight);
        }
      else
        {
          emacs_abort ();
        }

      Fputhash (object,
                dump_off_to_lisp(dump_queue->next_sequence_number++),
                dump_queue->sequence_numbers);
    }
  else
    {
      /* Object was already on the queue.  It's okay for an object to
         be on multiple queues so long as we maintain order
         invariants: attempting to dump an object multiple times is
         harmless, and most of the time, an object is only referenced
         once before being dumped, making this code path uncommon.  */
      if (weight.value != WEIGHT_NONE.value)
        {
          if (EQ (weights, Qt))
            {
              /* Object previously had a zero weight.  Once we
                 incorporate the link weight attached to this call,
                 the object will have a single weight.  Put the object
                 on the appropriate single-weight queue.  */
              weights = Qnil;
	      struct dump_tailq *tailq;
              if (!use_single_queues)
		tailq = &dump_queue->fancy_weight_objects;
              else if (weight.value == WEIGHT_NORMAL.value)
		tailq = &dump_queue->one_weight_normal_objects;
              else if (weight.value == WEIGHT_STRONG.value)
		tailq = &dump_queue->one_weight_strong_objects;
              else
                emacs_abort ();
	      dump_tailq_prepend (tailq, object);
            }
          else if (use_single_queues && NILP (XCDR (weights)))
            dump_tailq_prepend (&dump_queue->fancy_weight_objects, object);
          dump_queue_push_weight (&weights, basis, weight);
        }
    }

  if (!BASE_EQ (weights, orig_weights))
    Fputhash (object, weights, dump_queue->link_weights);
}

static float
dump_calc_link_score (dump_off basis,
                      dump_off link_basis,
                      dump_off link_weight)
{
  float distance = (float)(basis - link_basis);
  eassert (distance >= 0);
  float link_score = powf (distance, -0.2f);
  return powf (link_score, (float) link_weight / 1000.0f);
}

/* Compute the score for a queued object.

   OBJECT is the object to query, which must currently be queued for
   dumping.  BASIS is the offset at which we would be
   dumping the object; score is computed relative to BASIS and the
   various BASIS values supplied to dump_add_link_weight --- the
   further an object is from its referrers, the greater the
   score.  */
static float
dump_queue_compute_score (struct dump_queue *dump_queue,
                          Lisp_Object object,
                          dump_off basis)
{
  float score = 0;
  Lisp_Object object_link_weights =
    Fgethash (object, dump_queue->link_weights, Qnil);
  if (EQ (object_link_weights, Qt))
    object_link_weights = Qnil;
  while (!NILP (object_link_weights))
    {
      Lisp_Object basis_weight_pair = dump_pop (&object_link_weights);
      dump_off link_basis = dump_off_from_lisp (XCAR (basis_weight_pair));
      dump_off link_weight = dump_off_from_lisp (XCDR (basis_weight_pair));
      score += dump_calc_link_score (basis, link_basis, link_weight);
    }
  return score;
}

/* Scan the fancy part of the dump queue.

   BASIS is the position at which to evaluate the score function,
   usually ctx->offset.

   If we have at least one entry in the queue, return the pointer (in
   the singly-linked list) to the cons containing the object via
   *OUT_HIGHEST_SCORE_CONS_PTR and return its score.

   If the queue is empty, set *OUT_HIGHEST_SCORE_CONS_PTR to NULL
   and return negative infinity.  */
static float
dump_queue_scan_fancy (struct dump_queue *dump_queue,
                       dump_off basis,
                       Lisp_Object **out_highest_score_cons_ptr)
{
  Lisp_Object *cons_ptr = &dump_queue->fancy_weight_objects.head;
  Lisp_Object *highest_score_cons_ptr = NULL;
  float highest_score = -INFINITY;
  bool first = true;

  while (!NILP (*cons_ptr))
    {
      Lisp_Object queued_object = XCAR (*cons_ptr);
      float score = dump_queue_compute_score (dump_queue, queued_object, basis);
      if (first || score >= highest_score)
        {
          highest_score_cons_ptr = cons_ptr;
          highest_score = score;
          if (first)
            first = false;
        }
      cons_ptr = &XCONS (*cons_ptr)->u.s.u.cdr;
    }

  *out_highest_score_cons_ptr = highest_score_cons_ptr;
  return highest_score;
}

/* Return the sequence number of OBJECT.

   Return -1 if object doesn't have a sequence number.  This situation
   can occur when we've double-queued an object.  If this happens, we
   discard the errant object and try again.  */
static dump_off
dump_queue_sequence (struct dump_queue *dump_queue,
                     Lisp_Object object)
{
  Lisp_Object n = Fgethash (object, dump_queue->sequence_numbers, Qnil);
  return NILP (n) ? -1 : dump_off_from_lisp (n);
}

/* Find score and sequence at head of a one-weight object queue.

   Transparently discard stale objects from head of queue.  BASIS
   is the baseness for score computation.

   We organize these queues so that score is strictly decreasing, so
   examining the head is sufficient.  */
static void
dump_queue_find_score_of_one_weight_queue (struct dump_queue *dump_queue,
					   dump_off basis,
					   struct dump_tailq *one_weight_queue,
					   float *out_score,
					   int *out_sequence)
{
  /* Transparently discard stale objects from the head of this queue.  */
  do
    {
      if (dump_tailq_empty_p (one_weight_queue))
        {
          *out_score = -INFINITY;
          *out_sequence = 0;
        }
      else
        {
          Lisp_Object head = dump_tailq_peek (one_weight_queue);
          *out_sequence = dump_queue_sequence (dump_queue, head);
          if (*out_sequence < 0)
            dump_tailq_pop (one_weight_queue);
          else
            *out_score =
              dump_queue_compute_score (dump_queue, head, basis);
        }
    }
  while (*out_sequence < 0);
}

/* Pop the next object to dump from the dump queue.

   BASIS is the dump offset at which to evaluate score.

   The object returned is the queued object with the greatest score;
   by side effect, the object is removed from the dump queue.
   The dump queue must not be empty.  */
static Lisp_Object
dump_queue_dequeue (struct dump_queue *dump_queue, dump_off basis)
{
  eassert (BASE_EQ (Fhash_table_count (dump_queue->sequence_numbers),
		    Fhash_table_count (dump_queue->link_weights)));

  eassert (XFIXNUM (Fhash_table_count (dump_queue->sequence_numbers))
	   <= (dump_tailq_length (&dump_queue->fancy_weight_objects)
	       + dump_tailq_length (&dump_queue->zero_weight_objects)
	       + dump_tailq_length (&dump_queue->one_weight_normal_objects)
	       + dump_tailq_length (&dump_queue->one_weight_strong_objects)));

  dump_trace
    (("dump_queue_dequeue basis=%"PRIdDUMP_OFF" fancy=%"PRIdPTR
      " zero=%"PRIdPTR" normal=%"PRIdPTR" strong=%"PRIdPTR" hash=%td\n"),
     basis,
     dump_tailq_length (&dump_queue->fancy_weight_objects),
     dump_tailq_length (&dump_queue->zero_weight_objects),
     dump_tailq_length (&dump_queue->one_weight_normal_objects),
     dump_tailq_length (&dump_queue->one_weight_strong_objects),
     (ptrdiff_t) XHASH_TABLE (dump_queue->link_weights)->count);

  static const int nr_candidates = 3;
  struct candidate
  {
    float score;
    dump_off sequence;
  } candidates[nr_candidates];

  Lisp_Object *fancy_cons = NULL;
  candidates[0].sequence = 0;
  do
    {
      if (candidates[0].sequence < 0)
        *fancy_cons = XCDR (*fancy_cons);  /* Discard stale object.  */
      candidates[0].score = dump_queue_scan_fancy (dump_queue, basis,
						   &fancy_cons);
      candidates[0].sequence =
        candidates[0].score > -INFINITY
        ? dump_queue_sequence (dump_queue, XCAR (*fancy_cons))
        : 0;
    }
  while (candidates[0].sequence < 0);

  dump_queue_find_score_of_one_weight_queue
    (dump_queue, basis,
     &dump_queue->one_weight_normal_objects,
     &candidates[1].score,
     &candidates[1].sequence);

  dump_queue_find_score_of_one_weight_queue
    (dump_queue, basis,
     &dump_queue->one_weight_strong_objects,
     &candidates[2].score,
     &candidates[2].sequence);

  int best = -1;
  for (int i = 0; i < nr_candidates; ++i)
    {
      eassert (candidates[i].sequence >= 0);
      if (candidates[i].score > -INFINITY
	  && (best < 0
	      || candidates[i].score > candidates[best].score
	      || (candidates[i].score == candidates[best].score
		  && candidates[i].sequence < candidates[best].sequence)))
        best = i;
    }

  Lisp_Object result;
  const char *src;
  if (best < 0)
    {
      src = "zero";
      result = dump_tailq_pop (&dump_queue->zero_weight_objects);
    }
  else if (best == 0)
    {
      src = "fancy";
      result = dump_tailq_pop (&dump_queue->fancy_weight_objects);
    }
  else if (best == 1)
    {
      src = "normal";
      result = dump_tailq_pop (&dump_queue->one_weight_normal_objects);
    }
  else if (best == 2)
    {
      src = "strong";
      result = dump_tailq_pop (&dump_queue->one_weight_strong_objects);
    }
  else
    emacs_abort ();

  EMACS_UINT uresult = XLI (result);
  dump_trace ("  result score=%f src=%s object=%0*"pI"x\n",
              best < 0 ? -1.0 : (double) candidates[best].score,
	      src, EMACS_INT_XDIGITS, uresult);

  {
    Lisp_Object weights = Fgethash (result, dump_queue->link_weights, Qnil);
    while (!NILP (weights) && CONSP (weights))
      {
        Lisp_Object basis_weight_pair = dump_pop (&weights);
        dump_off link_basis =
          dump_off_from_lisp (XCAR (basis_weight_pair));
        dump_off link_weight =
          dump_off_from_lisp (XCDR (basis_weight_pair));
	dump_trace
	  ("    link_basis=%d distance=%d weight=%d contrib=%f\n",
	   link_basis,
	   basis - link_basis,
	   link_weight,
	   (double) dump_calc_link_score (basis, link_basis, link_weight));
      }
  }

  Fremhash (result, dump_queue->link_weights);
  Fremhash (result, dump_queue->sequence_numbers);
  return result;
}

/* Return whether we need to write OBJECT to the dump file.  */
static bool
dump_object_needs_dumping_p (Lisp_Object object)
{
  return !(FIXNUMP (object));
}

static void
dump_enqueue_object (struct dump_context *ctx,
                     Lisp_Object object,
                     struct link_weight weight)
{
  if (dump_object_needs_dumping_p (object))
    {
      dump_off state = dump_recall_object (ctx, object);
      bool already_dumped_object = state > DUMP_OBJECT_NOT_SEEN;
      if (ctx->flags.assert_already_seen)
        eassert (already_dumped_object);
      if (!already_dumped_object)
        {
          if (state == DUMP_OBJECT_NOT_SEEN)
            {
              state = DUMP_OBJECT_ON_NORMAL_QUEUE;
              dump_remember_object (ctx, object, state);
            }
          /* Note that we call dump_queue_enqueue even if the object
             is already on the normal queue: multiple enqueue calls
             can increase the object's weight.  */
          if (state == DUMP_OBJECT_ON_NORMAL_QUEUE)
            dump_queue_enqueue (&ctx->dump_queue,
                                object,
                                ctx->offset,
                                weight);
        }
    }
  /* Always remember the path to this object.  */
  dump_note_reachable (ctx, object);
}

static void
print_paths_to_root_1 (struct dump_context *ctx,
                       Lisp_Object object,
                       int level)
{
  Lisp_Object referrers = Fgethash (object, ctx->referrers, Qnil);
  while (!NILP (referrers))
    {
      Lisp_Object referrer = XCAR (referrers);
      referrers = XCDR (referrers);
      Lisp_Object repr = Fprin1_to_string (referrer, Qnil, Qnil);
      for (int i = 0; i < level; ++i)
	putc (' ', stderr);
      fwrite (SDATA (repr), 1, SBYTES (repr), stderr);
      putc ('\n', stderr);
      print_paths_to_root_1 (ctx, referrer, level + 1);
    }
}

static void
print_paths_to_root (struct dump_context *ctx, Lisp_Object object)
{
  print_paths_to_root_1 (ctx, object, 0);
}

static void
dump_remember_cold_op (struct dump_context *ctx,
                       enum cold_op op,
                       Lisp_Object arg)
{
  if (ctx->flags.dump_object_contents)
    dump_push (&ctx->cold_queue, Fcons (make_fixnum (op), arg));
}

/* Add a dump relocation that points into Emacs.

   Add a relocation that updates the pointer stored at DUMP_OFFSET to
   point into the Emacs binary upon dump load.  The pointer-sized
   value at DUMP_OFFSET in the dump file should contain a number
   relative to emacs_basis().  */
static void
dump_reloc_dump_to_emacs_ptr_raw (struct dump_context *ctx,
                                  dump_off dump_offset)
{
  if (ctx->flags.dump_object_contents)
    dump_push (&ctx->dump_relocs[EARLY_RELOCS],
               list2 (make_fixnum (RELOC_DUMP_TO_EMACS_PTR_RAW),
                      dump_off_to_lisp (dump_offset)));
}

/* Add a dump relocation that points a Lisp_Object back at the dump.

   Add a relocation that updates the Lisp_Object at DUMP_OFFSET in the
   dump to point to another object in the dump.  The Lisp_Object-sized
   value at DUMP_OFFSET in the dump file should contain the offset of
   the target object relative to the start of the dump.  */
static void
dump_reloc_dump_to_dump_lv (struct dump_context *ctx,
                            dump_off dump_offset,
                            enum Lisp_Type type)
{
  if (!ctx->flags.dump_object_contents)
    return;

  int reloc_type;
  switch (type)
    {
    case Lisp_Symbol:
    case Lisp_String:
    case Lisp_Vectorlike:
    case Lisp_Cons:
    case Lisp_Float:
      reloc_type = RELOC_DUMP_TO_DUMP_LV + type;
      break;
    default:
      emacs_abort ();
    }

  dump_push (&ctx->dump_relocs[EARLY_RELOCS],
             list2 (make_fixnum (reloc_type),
                    dump_off_to_lisp (dump_offset)));
}

/* Add a dump relocation that points a raw pointer back at the dump.

   Add a relocation that updates the raw pointer at DUMP_OFFSET in the
   dump to point to another object in the dump.  The pointer-sized
   value at DUMP_OFFSET in the dump file should contain the offset of
   the target object relative to the start of the dump.  */
static void
dump_reloc_dump_to_dump_ptr_raw (struct dump_context *ctx,
                                 dump_off dump_offset)
{
  if (ctx->flags.dump_object_contents)
    dump_push (&ctx->dump_relocs[EARLY_RELOCS],
               list2 (make_fixnum (RELOC_DUMP_TO_DUMP_PTR_RAW),
                      dump_off_to_lisp (dump_offset)));
}

/* Add a dump relocation that points to a Lisp object in Emacs.

   Add a relocation that updates the Lisp_Object at DUMP_OFFSET in the
   dump to point to a lisp object in Emacs.  The Lisp_Object-sized
   value at DUMP_OFFSET in the dump file should contain the offset of
   the target object relative to emacs_basis().  TYPE is the type of
   Lisp value.  */
static void
dump_reloc_dump_to_emacs_lv (struct dump_context *ctx,
                             dump_off dump_offset,
                             enum Lisp_Type type)
{
  if (!ctx->flags.dump_object_contents)
    return;

  int reloc_type;
  switch (type)
    {
    case Lisp_String:
    case Lisp_Vectorlike:
    case Lisp_Cons:
    case Lisp_Float:
      reloc_type = RELOC_DUMP_TO_EMACS_LV + type;
      break;
    default:
      emacs_abort ();
    }

  dump_push (&ctx->dump_relocs[EARLY_RELOCS],
             list2 (make_fixnum (reloc_type),
                    dump_off_to_lisp (dump_offset)));
}

/* Add an Emacs relocation that copies arbitrary bytes from the dump.

   When the dump is loaded, Emacs copies SIZE bytes from OFFSET in
   dump to LOCATION in the Emacs data section.  This copying happens
   after other relocations, so it's all right to, say, copy a
   Lisp_Object (since by the time we copy the Lisp_Object, it'll have
   been adjusted to account for the location of the running Emacs and
   dump file).  */
static void
dump_emacs_reloc_copy_from_dump (struct dump_context *ctx, dump_off dump_offset,
				 void *emacs_ptr, dump_off size)
{
  eassert (size >= 0);
  eassert (size < (1 << EMACS_RELOC_LENGTH_BITS));

  if (!ctx->flags.dump_object_contents)
    return;

  if (size == 0)
    return;

  eassert (dump_offset >= 0);
  dump_push (&ctx->emacs_relocs,
             list4 (make_fixnum (RELOC_EMACS_COPY_FROM_DUMP),
                    dump_off_to_lisp (emacs_offset (emacs_ptr)),
                    dump_off_to_lisp (dump_offset),
                    dump_off_to_lisp (size)));
}

/* Add an Emacs relocation that sets values to arbitrary bytes.

   When the dump is loaded, Emacs copies SIZE bytes from the
   relocation itself to the adjusted location inside Emacs EMACS_PTR.
   SIZE is the number of bytes to copy.  See struct emacs_reloc for
   the maximum size that this mechanism can support.  The value comes
   from VALUE_PTR.
 */
static void
dump_emacs_reloc_immediate (struct dump_context *ctx,
                            const void *emacs_ptr,
                            const void *value_ptr,
                            dump_off size)
{
  if (!ctx->flags.dump_object_contents)
    return;

  intmax_t value = 0;
  eassert (size <= sizeof (value));
  memcpy (&value, value_ptr, size);
  dump_push (&ctx->emacs_relocs,
             list4 (make_fixnum (RELOC_EMACS_IMMEDIATE),
                    dump_off_to_lisp (emacs_offset (emacs_ptr)),
                    intmax_t_to_lisp (value),
                    dump_off_to_lisp (size)));
}

#define DEFINE_EMACS_IMMEDIATE_FN(fnname, type)                         \
  static void                                                           \
  fnname (struct dump_context *ctx,                                     \
          const type *emacs_ptr,                                        \
          type value)                                                   \
  {                                                                     \
    dump_emacs_reloc_immediate (                                        \
      ctx, emacs_ptr, &value, sizeof (value));                          \
  }

DEFINE_EMACS_IMMEDIATE_FN (dump_emacs_reloc_immediate_lv, Lisp_Object)
DEFINE_EMACS_IMMEDIATE_FN (dump_emacs_reloc_immediate_ptrdiff_t, ptrdiff_t)
DEFINE_EMACS_IMMEDIATE_FN (dump_emacs_reloc_immediate_intmax_t, intmax_t)
DEFINE_EMACS_IMMEDIATE_FN (dump_emacs_reloc_immediate_int, int)
DEFINE_EMACS_IMMEDIATE_FN (dump_emacs_reloc_immediate_bool, bool)

/* Add an emacs relocation that makes a raw pointer in Emacs point
   into the dump.  */
static void
dump_emacs_reloc_to_dump_ptr_raw (struct dump_context *ctx,
				  const void *emacs_ptr, dump_off dump_offset)
{
  if (!ctx->flags.dump_object_contents)
    return;

  dump_push (&ctx->emacs_relocs,
             list3 (make_fixnum (RELOC_EMACS_DUMP_PTR_RAW),
                    dump_off_to_lisp (emacs_offset (emacs_ptr)),
                    dump_off_to_lisp (dump_offset)));
}

/* Add an emacs relocation that points into the dump.

   When the dump is loaded, the Lisp_Object at EMACS_ROOT in Emacs to
   point to VALUE.  VALUE can be any Lisp value; this function
   automatically queues the value for dumping if necessary.  */
static void
dump_emacs_reloc_to_lv (struct dump_context *ctx,
			Lisp_Object const *emacs_ptr,
                        Lisp_Object value)
{
  if (dump_object_self_representing_p (value))
    dump_emacs_reloc_immediate_lv (ctx, emacs_ptr, value);
  else
    {
      if (ctx->flags.dump_object_contents)
        /* Conditionally use RELOC_EMACS_EMACS_LV or
           RELOC_EMACS_DUMP_LV depending on where the target object
           lives.  We could just have decode_emacs_reloc pick the
           right type, but we might as well maintain the invariant
           that the types on ctx->emacs_relocs correspond to the types
           of emacs_relocs we actually emit.  */
	dump_push (&ctx->emacs_relocs,
		   list3 (make_fixnum (dump_object_emacs_ptr (value)
				       ? RELOC_EMACS_EMACS_LV
				       : RELOC_EMACS_DUMP_LV),
			  dump_off_to_lisp (emacs_offset (emacs_ptr)),
			  value));
      dump_enqueue_object (ctx, value, WEIGHT_NONE);
    }
}

/* Add an emacs relocation that makes a raw pointer in Emacs point
   back into the Emacs image.  */
static void
dump_emacs_reloc_to_emacs_ptr_raw (struct dump_context *ctx, void *emacs_ptr,
				   void const *target_emacs_ptr)
{
  if (!ctx->flags.dump_object_contents)
    return;

  dump_push (&ctx->emacs_relocs,
             list3 (make_fixnum (RELOC_EMACS_EMACS_PTR_RAW),
                    dump_off_to_lisp (emacs_offset (emacs_ptr)),
                    dump_off_to_lisp (emacs_offset (target_emacs_ptr))));
}

/* Add an Emacs relocation that makes a raw pointer in Emacs point to
   a different part of Emacs.  */

enum dump_fixup_type
  {
    DUMP_FIXUP_LISP_OBJECT,
    DUMP_FIXUP_LISP_OBJECT_RAW,
    DUMP_FIXUP_PTR_DUMP_RAW,
    DUMP_FIXUP_BIGNUM_DATA,
  };

enum dump_lv_fixup_type
  {
    LV_FIXUP_LISP_OBJECT,
    LV_FIXUP_RAW_POINTER,
  };

/* Make something in the dump point to a lisp object.

   CTX is a dump context.  DUMP_OFFSET is the location in the dump to
   fix.  VALUE is the object to which the location in the dump
   should point.

   If FIXUP_SUBTYPE is LV_FIXUP_LISP_OBJECT, we expect a Lisp_Object
   at DUMP_OFFSET.  If it's LV_FIXUP_RAW_POINTER, we expect a pointer.
 */
static void
dump_remember_fixup_lv (struct dump_context *ctx,
                        dump_off dump_offset,
                        Lisp_Object value,
                        enum dump_lv_fixup_type fixup_subtype)
{
  if (!ctx->flags.dump_object_contents)
    return;

  dump_push (&ctx->fixups,
	     list3 (make_fixnum (fixup_subtype == LV_FIXUP_LISP_OBJECT
				 ? DUMP_FIXUP_LISP_OBJECT
				 : DUMP_FIXUP_LISP_OBJECT_RAW),
		    dump_off_to_lisp (dump_offset),
		    value));
}

/* Remember to fix up the dump file such that the pointer-sized value
   at DUMP_OFFSET points to NEW_DUMP_OFFSET in the dump file and to
   its absolute address at runtime.  */
static void
dump_remember_fixup_ptr_raw (struct dump_context *ctx,
                             dump_off dump_offset,
                             dump_off new_dump_offset)
{
  if (!ctx->flags.dump_object_contents)
    return;

  /* We should not be generating relocations into the
     to-be-copied-into-Emacs dump region.  */
  eassert (ctx->header.discardable_start == 0
	   || new_dump_offset < ctx->header.discardable_start
	   || (ctx->header.cold_start != 0
	       && new_dump_offset >= ctx->header.cold_start));

  dump_push (&ctx->fixups,
	     list3 (make_fixnum (DUMP_FIXUP_PTR_DUMP_RAW),
		    dump_off_to_lisp (dump_offset),
		    dump_off_to_lisp (new_dump_offset)));
}

static void
dump_root_visitor (Lisp_Object const *root_ptr, enum gc_root_type type,
		   void *data)
{
  struct dump_context *ctx = data;
  Lisp_Object value = *root_ptr;
  if (type == GC_ROOT_C_SYMBOL)
    {
      eassert (dump_builtin_symbol_p (value));
      /* Remember to dump the object itself later along with all the
         rest of the copied-to-Emacs objects.  */
      if (dump_set_referrer (ctx))
	ctx->current_referrer = build_string ("built-in symbol list");
      dump_enqueue_object (ctx, value, WEIGHT_NONE);
      dump_clear_referrer (ctx);
    }
  else
    {
      if (type == GC_ROOT_STATICPRO)
        Fputhash (dump_off_to_lisp (emacs_offset (root_ptr)),
                  Qt,
                  ctx->staticpro_table);
      if (root_ptr != &Vinternal_interpreter_environment)
        {
	  if (dump_set_referrer (ctx))
	    ctx->current_referrer
	      = dump_ptr_referrer ("emacs root", root_ptr);
          dump_emacs_reloc_to_lv (ctx, root_ptr, *root_ptr);
          dump_clear_referrer (ctx);
        }
    }
}

/* Kick off the dump process by queuing up the static GC roots.  */
static void
dump_roots (struct dump_context *ctx)
{
  struct gc_root_visitor visitor = { .visit = dump_root_visitor,
				     .data = ctx };
  visit_static_gc_roots (visitor);
}

enum { PDUMPER_MAX_OBJECT_SIZE = 2048 };

static dump_off
field_relpos (const void *in_start, const void *in_field)
{
  ptrdiff_t in_start_val = (ptrdiff_t) in_start;
  ptrdiff_t in_field_val = (ptrdiff_t) in_field;
  eassert (in_start_val <= in_field_val);
  ptrdiff_t relpos = in_field_val - in_start_val;
  /* The following assertion attempts to detect bugs whereby IN_START
     and IN_FIELD don't point to the same object/structure, on the
     assumption that a too-large difference between them is
     suspicious.  As of Apr 2019 the largest object we dump -- 'struct
     buffer' -- is slightly smaller than 1KB, and we want to leave
     some margin for future extensions.  If the assertion below is
     ever violated, make sure the two pointers indeed point into the
     same object, and if so, enlarge the value of PDUMPER_MAX_OBJECT_SIZE.  */
  eassert (relpos < PDUMPER_MAX_OBJECT_SIZE);
  return (dump_off) relpos;
}

static void
cpyptr (void *out, const void *in)
{
  memcpy (out, in, sizeof (void *));
}

/* Convenience macro for regular assignment.  */
#define DUMP_FIELD_COPY(out, in, name) \
  ((out)->name = (in)->name)

static void
dump_field_lv_or_rawptr (struct dump_context *ctx,
                         void *out,
                         const void *in_start,
                         const void *in_field,
                         /* opt */ const enum Lisp_Type *ptr_raw_type,
                         struct link_weight weight)
{
  eassert (ctx->obj_offset > 0);

  Lisp_Object value;
  dump_off relpos = field_relpos (in_start, in_field);
  void *out_field = (char *) out + relpos;
  bool is_ptr_raw = (ptr_raw_type != NULL);

  if (!is_ptr_raw)
    {
      memcpy (&value, in_field, sizeof (value));
      if (dump_object_self_representing_p (value))
        {
          memcpy (out_field, &value, sizeof (value));
          return;
        }
    }
  else
    {
      void *ptrval;
      cpyptr (&ptrval, in_field);
      if (ptrval == NULL)
        return; /* Nothing to do.  */
      switch (*ptr_raw_type)
        {
        case Lisp_Symbol:
          value = make_lisp_symbol (ptrval);
          break;
        case Lisp_String:
        case Lisp_Vectorlike:
        case Lisp_Cons:
        case Lisp_Float:
          value = make_lisp_ptr (ptrval, *ptr_raw_type);
          break;
        default:
          emacs_abort ();
        }
    }

  /* Now value is the Lisp_Object to which we want to point whether or
     not the field is a raw pointer (in which case we just synthesized
     the Lisp_Object ourselves) or a Lisp_Object (in which case we
     just copied the thing).  Add a fixup or relocation.  */

  intptr_t out_value;
  dump_off out_field_offset = ctx->obj_offset + relpos;
  dump_off target_offset = dump_recall_object (ctx, value);
  enum { DANGEROUS = false };
  if (DANGEROUS
      && target_offset > 0 && dump_object_emacs_ptr (value) == NULL)
    {
      /* We've already dumped the referenced object, so we can emit
         the value and a relocation directly instead of indirecting
         through a fixup.  */
      out_value = target_offset;
      if (is_ptr_raw)
        dump_reloc_dump_to_dump_ptr_raw (ctx, out_field_offset);
      else
        dump_reloc_dump_to_dump_lv (ctx, out_field_offset, XTYPE (value));
    }
  else
    {
      /* We don't know about the target object yet, so add a fixup.
         When we process the fixup, we'll have dumped the target
         object.  */
      out_value = (intptr_t) 0xDEADF00D;
      dump_remember_fixup_lv (ctx,
                              out_field_offset,
                              value,
                              ( is_ptr_raw
                                ? LV_FIXUP_RAW_POINTER
                                : LV_FIXUP_LISP_OBJECT ));
      dump_enqueue_object (ctx, value, weight);
    }

  memcpy (out_field, &out_value, sizeof (out_value));
}

/* Set a pointer field on an output object during dump.

   CTX is the dump context.  OUT is a pointer to the dump output
   object.  IN_START is the start of the current Emacs object.
   IN_FIELD is a pointer to the field in that object.  TYPE is the
   type of pointer to which IN_FIELD points.
 */
static void
dump_field_lv_rawptr (struct dump_context *ctx,
                      void *out,
                      const void *in_start,
                      const void *in_field,
                      enum Lisp_Type type,
                      struct link_weight weight)
{
  dump_field_lv_or_rawptr (ctx, out, in_start, in_field, &type, weight);
}

/* Set a Lisp_Object field on an output object during dump.

   CTX is a dump context.  OUT is a pointer to the dump output object.
   IN_START is the start of the current Emacs object.  IN_FIELD is a
   pointer to a Lisp_Object field in that object.

   Arrange for the dump to contain fixups and relocations such that,
   at load time, the given field of the output object contains a valid
   Lisp_Object pointing to the same notional object that *IN_FIELD
   contains now.

   See idomatic usage below.  */
static void
dump_field_lv (struct dump_context *ctx,
               void *out,
               const void *in_start,
               const Lisp_Object *in_field,
               struct link_weight weight)
{
  dump_field_lv_or_rawptr (ctx, out, in_start, in_field, NULL, weight);
}

/* Note that we're going to add a manual fixup for the given field
   later.  */
static void
dump_field_fixup_later (struct dump_context *ctx,
                        void *out,
                        const void *in_start,
                        const void *in_field)
{
  /* TODO: more error checking.  */
  (void) field_relpos (in_start, in_field);
}

/* Mark an output object field, which is as wide as a pointer, as being
   fixed up to point to a specific offset in the dump.  */
static void
dump_field_ptr_to_dump_offset (struct dump_context *ctx,
                               void *out,
                               const void *in_start,
                               const void *in_field,
                               dump_off target_dump_offset)
{
  eassert (ctx->obj_offset > 0);
  if (!ctx->flags.dump_object_contents)
    return;

  dump_off relpos = field_relpos (in_start, in_field);
  dump_reloc_dump_to_dump_ptr_raw (ctx, ctx->obj_offset + relpos);
  intptr_t outval = target_dump_offset;
  memcpy ((char *) out + relpos, &outval, sizeof (outval));
}

/* Mark a field as pointing to a place inside Emacs.

   CTX is the dump context.  OUT points to the out-object for the
   current dump function.  IN_START points to the start of the object
   being dumped.  IN_FIELD points to the field inside the object being
   dumped that we're dumping.  The contents of this field (which
   should be as wide as a pointer) are the Emacs pointer to dump.

 */
static void
dump_field_emacs_ptr (struct dump_context *ctx,
                      void *out,
                      const void *in_start,
                      const void *in_field)
{
  eassert (ctx->obj_offset > 0);
  if (!ctx->flags.dump_object_contents)
    return;

  dump_off relpos = field_relpos (in_start, in_field);
  void *abs_emacs_ptr;
  cpyptr (&abs_emacs_ptr, in_field);
  intptr_t rel_emacs_ptr = 0;
  if (abs_emacs_ptr)
    {
      rel_emacs_ptr = emacs_offset ((void *)abs_emacs_ptr);
      dump_reloc_dump_to_emacs_ptr_raw (ctx, ctx->obj_offset + relpos);
    }
  cpyptr ((char *) out + relpos, &rel_emacs_ptr);
}

static void
dump_object_start_pseudovector (struct dump_context *ctx,
				union vectorlike_header *out_hdr,
				const union vectorlike_header *in_hdr)
{
  eassert (in_hdr->size & PSEUDOVECTOR_FLAG);
  ptrdiff_t vec_size = vectorlike_nbytes (in_hdr);
  dump_object_start (ctx, out_hdr, (dump_off) vec_size);
  *out_hdr = *in_hdr;
}

/* Need a macro for alloca.  */
#define START_DUMP_PVEC(ctx, hdr, type, out)                  \
  const union vectorlike_header *in_hdr = (hdr);	      \
  type *out = alloca (vectorlike_nbytes (in_hdr));	      \
  dump_object_start_pseudovector (ctx, &out->header, in_hdr)

static dump_off
finish_dump_pvec (struct dump_context *ctx,
                  union vectorlike_header *out_hdr)
{
  return dump_object_finish (ctx, out_hdr, vectorlike_nbytes (out_hdr));
}

static void
dump_pseudovector_lisp_fields (struct dump_context *ctx,
			       union vectorlike_header *out_hdr,
			       const union vectorlike_header *in_hdr)
{
  const struct Lisp_Vector *in = (const struct Lisp_Vector *) in_hdr;
  struct Lisp_Vector *out = (struct Lisp_Vector *) out_hdr;
  ptrdiff_t size = in->header.size;
  eassert (size & PSEUDOVECTOR_FLAG);
  size &= PSEUDOVECTOR_SIZE_MASK;
  for (ptrdiff_t i = 0; i < size; ++i)
    dump_field_lv (ctx, out, in, &in->contents[i], WEIGHT_STRONG);
}

static dump_off
dump_cons (struct dump_context *ctx, const struct Lisp_Cons *cons)
{
#if CHECK_STRUCTS && !defined (HASH_Lisp_Cons_00EEE63F67)
# error "Lisp_Cons changed. See CHECK_STRUCTS comment in config.h."
#endif
  struct Lisp_Cons out;
  dump_object_start (ctx, &out, sizeof (out));
  dump_field_lv (ctx, &out, cons, &cons->u.s.car, WEIGHT_STRONG);
  dump_field_lv (ctx, &out, cons, &cons->u.s.u.cdr, WEIGHT_NORMAL);
  return dump_object_finish (ctx, &out, sizeof (out));
}

static dump_off
dump_interval_tree (struct dump_context *ctx,
                    INTERVAL tree,
                    dump_off parent_offset)
{
#if CHECK_STRUCTS && !defined (HASH_interval_1B38941C37)
# error "interval changed. See CHECK_STRUCTS comment in config.h."
#endif
  /* TODO: output tree breadth-first?  */
  struct interval out;
  dump_object_start (ctx, &out, sizeof (out));
  DUMP_FIELD_COPY (&out, tree, total_length);
  DUMP_FIELD_COPY (&out, tree, position);
  if (tree->left)
    dump_field_fixup_later (ctx, &out, tree, &tree->left);
  if (tree->right)
    dump_field_fixup_later (ctx, &out, tree, &tree->right);
  if (!tree->up_obj)
    {
      eassert (parent_offset != 0);
      dump_field_ptr_to_dump_offset (ctx, &out, tree, &tree->up.interval,
				     parent_offset);
    }
  else
    dump_field_lv (ctx, &out, tree, &tree->up.obj, WEIGHT_STRONG);
  DUMP_FIELD_COPY (&out, tree, up_obj);
  eassert (tree->gcmarkbit == 0);
  DUMP_FIELD_COPY (&out, tree, write_protect);
  DUMP_FIELD_COPY (&out, tree, visible);
  DUMP_FIELD_COPY (&out, tree, front_sticky);
  DUMP_FIELD_COPY (&out, tree, rear_sticky);
  dump_field_lv (ctx, &out, tree, &tree->plist, WEIGHT_STRONG);
  dump_off offset = dump_object_finish (ctx, &out, sizeof (out));
  if (tree->left)
      dump_remember_fixup_ptr_raw
	(ctx,
	 offset + dump_offsetof (struct interval, left),
	 dump_interval_tree (ctx, tree->left, offset));
  if (tree->right)
      dump_remember_fixup_ptr_raw
	(ctx,
	 offset + dump_offsetof (struct interval, right),
	 dump_interval_tree (ctx, tree->right, offset));
  return offset;
}

static dump_off
dump_string (struct dump_context *ctx, const struct Lisp_String *string)
{
#if CHECK_STRUCTS && !defined (HASH_Lisp_String_03B2DF1C8E)
# error "Lisp_String changed. See CHECK_STRUCTS comment in config.h."
#endif
  /* If we have text properties, write them _after_ the string so that
     at runtime, the prefetcher and cache will DTRT. (We access the
     string before its properties.).

     There's special code to dump string data contiguously later on.
     we seldom write to string data and never relocate it, so lumping
     it together at the end of the dump saves on COW faults.

     If, however, the string's size_byte field is -2, the string data
     is actually a pointer to Emacs data segment, so we can do even
     better by emitting a relocation instead of bothering to copy the
     string data.  */
  struct Lisp_String out;
  dump_object_start (ctx, &out, sizeof (out));
  DUMP_FIELD_COPY (&out, string, u.s.size);
  DUMP_FIELD_COPY (&out, string, u.s.size_byte);
  if (string->u.s.intervals)
    dump_field_fixup_later (ctx, &out, string, &string->u.s.intervals);

  if (string->u.s.size_byte == -2)
    /* String literal in Emacs rodata.  */
    dump_field_emacs_ptr (ctx, &out, string, &string->u.s.data);
  else
    {
      dump_field_fixup_later (ctx, &out, string, &string->u.s.data);
      dump_remember_cold_op (ctx,
                             COLD_OP_STRING,
			     make_lisp_ptr ((void *) string, Lisp_String));
    }

  dump_off offset = dump_object_finish (ctx, &out, sizeof (out));
  if (string->u.s.intervals)
    dump_remember_fixup_ptr_raw
      (ctx,
       offset + dump_offsetof (struct Lisp_String, u.s.intervals),
       dump_interval_tree (ctx, string->u.s.intervals, 0));

  return offset;
}

static dump_off
dump_marker (struct dump_context *ctx, const struct Lisp_Marker *marker)
{
#if CHECK_STRUCTS && !defined (HASH_Lisp_Marker_642DBAF866)
# error "Lisp_Marker changed. See CHECK_STRUCTS comment in config.h."
#endif

  START_DUMP_PVEC (ctx, &marker->header, struct Lisp_Marker, out);
  dump_pseudovector_lisp_fields (ctx, &out->header, &marker->header);
  DUMP_FIELD_COPY (out, marker, need_adjustment);
  DUMP_FIELD_COPY (out, marker, insertion_type);
  if (marker->buffer)
    {
      dump_field_lv_rawptr (ctx, out, marker, &marker->buffer,
			    Lisp_Vectorlike, WEIGHT_NORMAL);
      dump_field_lv_rawptr (ctx, out, marker, &marker->next,
			    Lisp_Vectorlike, WEIGHT_STRONG);
      DUMP_FIELD_COPY (out, marker, charpos);
      DUMP_FIELD_COPY (out, marker, bytepos);
    }
  return finish_dump_pvec (ctx, &out->header);
}

static dump_off
dump_interval_node (struct dump_context *ctx, struct itree_node *node)
{
#if CHECK_STRUCTS && !defined (HASH_itree_node_03626AFCA9)
# error "itree_node changed. See CHECK_STRUCTS comment in config.h."
#endif
  struct itree_node out;
  dump_object_start (ctx, &out, sizeof (out));
  if (node->parent)
    dump_field_fixup_later (ctx, &out, node, &node->parent);
  if (node->left)
    dump_field_fixup_later (ctx, &out, node, &node->left);
  if (node->right)
    dump_field_fixup_later (ctx, &out, node, &node->right);
  DUMP_FIELD_COPY (&out, node, begin);
  DUMP_FIELD_COPY (&out, node, end);
  DUMP_FIELD_COPY (&out, node, limit);
  DUMP_FIELD_COPY (&out, node, offset);
  DUMP_FIELD_COPY (&out, node, otick);
  dump_field_lv (ctx, &out, node, &node->data, WEIGHT_STRONG);
  DUMP_FIELD_COPY (&out, node, red);
  DUMP_FIELD_COPY (&out, node, rear_advance);
  DUMP_FIELD_COPY (&out, node, front_advance);
  dump_off offset = dump_object_finish (ctx, &out, sizeof (out));
  if (node->parent)
      dump_remember_fixup_ptr_raw
	(ctx,
	 offset + dump_offsetof (struct itree_node, parent),
	 dump_interval_node (ctx, node->parent));
  if (node->left)
      dump_remember_fixup_ptr_raw
	(ctx,
	 offset + dump_offsetof (struct itree_node, left),
	 dump_interval_node (ctx, node->left));
  if (node->right)
      dump_remember_fixup_ptr_raw
	(ctx,
	 offset + dump_offsetof (struct itree_node, right),
	 dump_interval_node (ctx, node->right));
  return offset;
}

static dump_off
dump_overlay (struct dump_context *ctx, const struct Lisp_Overlay *overlay)
{
#if CHECK_STRUCTS && !defined (HASH_Lisp_Overlay_5F9D7E02FC)
# error "Lisp_Overlay changed. See CHECK_STRUCTS comment in config.h."
#endif
  START_DUMP_PVEC (ctx, &overlay->header, struct Lisp_Overlay, out);
  dump_pseudovector_lisp_fields (ctx, &out->header, &overlay->header);
  dump_field_fixup_later (ctx, &out, overlay, &overlay->interval);
  dump_off offset = finish_dump_pvec (ctx, &out->header);
  dump_remember_fixup_ptr_raw
    (ctx,
     offset + dump_offsetof (struct Lisp_Overlay, interval),
     dump_interval_node (ctx, overlay->interval));
  return offset;
}

static void
dump_field_finalizer_ref (struct dump_context *ctx,
                          void *out,
                          const struct Lisp_Finalizer *finalizer,
                          struct Lisp_Finalizer *const *field)
{
  if (*field == &finalizers || *field == &doomed_finalizers)
    dump_field_emacs_ptr (ctx, out, finalizer, field);
  else
    dump_field_lv_rawptr (ctx, out, finalizer, field,
                          Lisp_Vectorlike,
                          WEIGHT_NORMAL);
}

static dump_off
dump_finalizer (struct dump_context *ctx,
                const struct Lisp_Finalizer *finalizer)
{
#if CHECK_STRUCTS && !defined (HASH_Lisp_Finalizer_D58E647CB8)
# error "Lisp_Finalizer changed. See CHECK_STRUCTS comment in config.h."
#endif
  START_DUMP_PVEC (ctx, &finalizer->header, struct Lisp_Finalizer, out);
  /* Do _not_ call dump_pseudovector_lisp_fields here: we dump the
     only Lisp field, finalizer->function, manually, so we can give it
     a low weight.  */
  dump_field_lv (ctx, out, finalizer, &finalizer->function, WEIGHT_NONE);
  dump_field_finalizer_ref (ctx, out, finalizer, &finalizer->prev);
  dump_field_finalizer_ref (ctx, out, finalizer, &finalizer->next);
  return finish_dump_pvec (ctx, &out->header);
}

#ifdef HAVE_TREE_SITTER
static dump_off
dump_treesit_compiled_query (struct dump_context *ctx,
			     struct Lisp_TS_Query *query)
{
  START_DUMP_PVEC (ctx, &query->header, struct Lisp_TS_Query, out);
  dump_field_lv (ctx, &out->language, query, &query->language, WEIGHT_STRONG);
  dump_field_lv (ctx, &out->source, query, &query->source, WEIGHT_STRONG);
  /* These will be recompiled after load from dump.  */
  out->query = NULL;
  out->cursor = NULL;
  return finish_dump_pvec (ctx, &out->header);
}
#endif

struct bignum_reload_info
{
  dump_off data_location;
  dump_off nlimbs;
};

static dump_off
dump_bignum (struct dump_context *ctx, Lisp_Object object)
{
#if CHECK_STRUCTS && !defined (HASH_Lisp_Bignum_661945DE2B)
# error "Lisp_Bignum changed. See CHECK_STRUCTS comment in config.h."
#endif
  const struct Lisp_Bignum *bignum = XBIGNUM (object);
  START_DUMP_PVEC (ctx, &bignum->header, struct Lisp_Bignum, out);
  static_assert (sizeof (out->value) >= sizeof (struct bignum_reload_info));
  dump_field_fixup_later (ctx, out, bignum, xbignum_val (object));
  dump_off bignum_offset = finish_dump_pvec (ctx, &out->header);
  if (ctx->flags.dump_object_contents)
    {
      /* Export the bignum into a blob in the cold section.  */
      dump_remember_cold_op (ctx, COLD_OP_BIGNUM, object);

      /* Write the offset of that exported blob here.  */
      dump_off value_offset
	= (bignum_offset
	   + (dump_off) offsetof (struct Lisp_Bignum, value));
      dump_push (&ctx->fixups,
		 list3 (make_fixnum (DUMP_FIXUP_BIGNUM_DATA),
			dump_off_to_lisp (value_offset),
			object));

      /* When we load the dump, slurp the data blob and turn it into a
         real bignum.  Attach the relocation to the start of the
         Lisp_Bignum instead of the actual mpz field so that the
         relocation offset is aligned.  The relocation-application
         code knows to actually advance past the header.  */
      dump_push (&ctx->dump_relocs[EARLY_RELOCS],
                 list2 (make_fixnum (RELOC_BIGNUM),
                        dump_off_to_lisp (bignum_offset)));
    }

  return bignum_offset;
}

static dump_off
dump_float (struct dump_context *ctx, const struct Lisp_Float *lfloat)
{
#if CHECK_STRUCTS && !defined (HASH_Lisp_Float_7E7D284C02)
# error "Lisp_Float changed. See CHECK_STRUCTS comment in config.h."
#endif
  eassert (ctx->header.cold_start);
  struct Lisp_Float out;
  dump_object_start (ctx, &out, sizeof (out));
  DUMP_FIELD_COPY (&out, lfloat, u.data);
  return dump_object_finish (ctx, &out, sizeof (out));
}

static void
dump_fwd_int (struct dump_context *ctx, const struct Lisp_Intfwd *intfwd)
{
#if CHECK_STRUCTS && !defined HASH_Lisp_Intfwd_4D887A7387
# error "Lisp_Intfwd changed. See CHECK_STRUCTS comment in config.h."
#endif
  dump_emacs_reloc_immediate_intmax_t (ctx, intfwd->intvar, *intfwd->intvar);
}

static void
dump_fwd_bool (struct dump_context *ctx, const struct Lisp_Boolfwd *boolfwd)
{
#if CHECK_STRUCTS && !defined (HASH_Lisp_Boolfwd_0EA1C7ADCC)
# error "Lisp_Boolfwd changed. See CHECK_STRUCTS comment in config.h."
#endif
  dump_emacs_reloc_immediate_bool (ctx, boolfwd->boolvar, *boolfwd->boolvar);
}

static void
dump_fwd_obj (struct dump_context *ctx, const struct Lisp_Objfwd *objfwd)
{
#if CHECK_STRUCTS && !defined (HASH_Lisp_Objfwd_45D3E513DC)
# error "Lisp_Objfwd changed. See CHECK_STRUCTS comment in config.h."
#endif
  if (NILP (Fgethash (dump_off_to_lisp (emacs_offset (objfwd->objvar)),
                      ctx->staticpro_table,
                      Qnil)))
    dump_emacs_reloc_to_lv (ctx, objfwd->objvar, *objfwd->objvar);
}

static void
dump_fwd_buffer_obj (struct dump_context *ctx,
                     const struct Lisp_Buffer_Objfwd *buffer_objfwd)
{
#if CHECK_STRUCTS && !defined (HASH_Lisp_Buffer_Objfwd_611EBD13FF)
# error "Lisp_Buffer_Objfwd changed. See CHECK_STRUCTS comment in config.h."
#endif
  struct Lisp_Buffer_Objfwd out;
  dump_off off;

  dump_object_start (ctx, &out, sizeof (out));
  DUMP_FIELD_COPY (&out, buffer_objfwd, type);
  DUMP_FIELD_COPY (&out, buffer_objfwd, offset);
  dump_field_lv (ctx, &out, buffer_objfwd, &buffer_objfwd->predicate,
                 WEIGHT_NORMAL);
  off = dump_object_finish (ctx, &out, sizeof out);

  /* Copy this fwd from the dump to the buffer fwd in Emacs.  */
  dump_emacs_reloc_copy_from_dump (ctx, off, (void *) buffer_objfwd,
				   sizeof out);
}

static void
dump_fwd (struct dump_context *ctx, lispfwd fwd)
{
#if CHECK_STRUCTS && !defined (HASH_Lisp_Fwd_Type_9CBA6EE55E)
# error "Lisp_Fwd_Type changed. See CHECK_STRUCTS comment in config.h."
#endif
  void const *p = fwd.fwdptr;

  switch (XFWDTYPE (fwd))
    {
    case Lisp_Fwd_Int:
      dump_fwd_int (ctx, p);
      break;
    case Lisp_Fwd_Bool:
      dump_fwd_bool (ctx, p);
      break;
    case Lisp_Fwd_Obj:
      dump_fwd_obj (ctx, p);
      break;
    case Lisp_Fwd_Buffer_Obj:
      dump_fwd_buffer_obj (ctx, p);
      break;
      /* The default kboard's contents are not meant to appear in the
	 dump file.  */
    case Lisp_Fwd_Kboard_Obj:
      break;
    default:
      emacs_abort ();
    }
}

static dump_off
dump_blv (struct dump_context *ctx,
          const struct Lisp_Buffer_Local_Value *blv)
{
#if CHECK_STRUCTS && !defined HASH_Lisp_Buffer_Local_Value_3C363FAC3C
# error "Lisp_Buffer_Local_Value changed. See CHECK_STRUCTS comment in config.h."
#endif
  struct Lisp_Buffer_Local_Value out;
  dump_object_start (ctx, &out, sizeof (out));
  DUMP_FIELD_COPY (&out, blv, local_if_set);
  DUMP_FIELD_COPY (&out, blv, found);
  if (blv->fwd.fwdptr)
    {
      eassert (XFWDTYPE (blv->fwd) != Lisp_Fwd_Buffer_Obj);
      dump_field_emacs_ptr (ctx, &out, blv, &blv->fwd.fwdptr);
    }
  dump_field_lv (ctx, &out, blv, &blv->where, WEIGHT_NORMAL);
  dump_field_lv (ctx, &out, blv, &blv->defcell, WEIGHT_STRONG);
  dump_field_lv (ctx, &out, blv, &blv->valcell, WEIGHT_STRONG);
  dump_off offset = dump_object_finish (ctx, &out, sizeof (out));
  if (blv->fwd.fwdptr)
    dump_fwd (ctx, blv->fwd);
  return offset;
}

static dump_off
dump_recall_symbol_aux (struct dump_context *ctx, Lisp_Object symbol)
{
  Lisp_Object symbol_aux = ctx->symbol_aux;
  if (NILP (symbol_aux))
    return 0;
  return dump_off_from_lisp (Fgethash (symbol, symbol_aux, make_fixnum (0)));
}

static void
dump_remember_symbol_aux (struct dump_context *ctx,
                          Lisp_Object symbol,
                          dump_off offset)
{
  Fputhash (symbol, dump_off_to_lisp (offset), ctx->symbol_aux);
}

/* Dump auxiliary information attached to SYMBOL, a symbol that will be
   copied into Emacs's core from the dump file.  If SYMBOL is localized,
   generate a copy of its buffer local storage and arrange that the
   symbol redirect to the same.  Otherwise, if SYMBOL is forwarded,
   arrange to restore the contents of the forwarding structure and/or
   dump its references as the case may be; the former is only necessary
   in the case of buffer objfwds, which are initialized at runtime.  */

static void
dump_pre_dump_symbol (struct dump_context *ctx, struct Lisp_Symbol *symbol)
{
  Lisp_Object symbol_lv = make_lisp_symbol (symbol);
  eassert (!dump_recall_symbol_aux (ctx, symbol_lv));
  if (dump_set_referrer (ctx))
    ctx->current_referrer = symbol_lv;
  switch (symbol->u.s.redirect)
    {
    case SYMBOL_LOCALIZED:
      dump_remember_symbol_aux (ctx, symbol_lv,
				dump_blv (ctx, symbol->u.s.val.blv));
      break;
    case SYMBOL_FORWARDED:
      dump_fwd (ctx, symbol->u.s.val.fwd);
      dump_remember_symbol_aux (ctx, symbol_lv,
				emacs_offset (symbol->u.s.val.fwd.fwdptr));
      break;
    default:
      break;
    }
  dump_clear_referrer (ctx);
}

static dump_off
dump_symbol (struct dump_context *ctx, Lisp_Object object,
	     dump_off offset)
{
#if CHECK_STRUCTS && !defined HASH_Lisp_Symbol_E0ADAF2F24
# error "Lisp_Symbol changed. See CHECK_STRUCTS comment in config.h."
#endif
#if CHECK_STRUCTS && !defined (HASH_symbol_redirect_EA72E4BFF5)
# error "symbol_redirect changed. See CHECK_STRUCTS comment in config.h."
#endif
  dump_off aux_offset;

  if (ctx->flags.defer_symbols)
    {
      if (offset != DUMP_OBJECT_ON_SYMBOL_QUEUE)
        {
	  eassert (offset == DUMP_OBJECT_ON_NORMAL_QUEUE
		   || offset == DUMP_OBJECT_NOT_SEEN);
	  dump_clear_referrer (ctx);
          struct dump_flags old_flags = ctx->flags;
          ctx->flags.dump_object_contents = false;
          ctx->flags.defer_symbols = false;
          dump_object (ctx, object);
          ctx->flags = old_flags;
	  if (dump_set_referrer (ctx))
	    ctx->current_referrer = object;

          offset = DUMP_OBJECT_ON_SYMBOL_QUEUE;
          dump_remember_object (ctx, object, offset);
          dump_push (&ctx->deferred_symbols, object);
        }
      return offset;
    }

  struct Lisp_Symbol *symbol = XSYMBOL (object);
  struct Lisp_Symbol out;
  dump_object_start (ctx, &out, sizeof (out));
  eassert (symbol->u.s.gcmarkbit == 0);
  DUMP_FIELD_COPY (&out, symbol, u.s.redirect);
  DUMP_FIELD_COPY (&out, symbol, u.s.trapped_write);
  DUMP_FIELD_COPY (&out, symbol, u.s.interned);
  DUMP_FIELD_COPY (&out, symbol, u.s.declared_special);
  dump_field_lv (ctx, &out, symbol, &symbol->u.s.name, WEIGHT_STRONG);
  switch (symbol->u.s.redirect)
    {
    case SYMBOL_PLAINVAL:
      dump_field_lv (ctx, &out, symbol, &symbol->u.s.val.value,
                     WEIGHT_NORMAL);
      break;
    case SYMBOL_VARALIAS:
      dump_field_lv_rawptr (ctx, &out, symbol,
                            &symbol->u.s.val.alias, Lisp_Symbol,
                            WEIGHT_NORMAL);
      break;
    case SYMBOL_LOCALIZED:
      dump_field_fixup_later (ctx, &out, symbol, &symbol->u.s.val.blv);
      break;
    case SYMBOL_FORWARDED:
      /* This forwarding descriptor is in Emacs's core, but the symbol
	 is initialized at runtime.  The next switch statement might
	 dump this value if it hasn't already been dumped by
	 dump_pre_dump_symbol.  */
      dump_field_emacs_ptr (ctx, &out, symbol, &symbol->u.s.val.fwd.fwdptr);
      break;

    default:
      emacs_abort ();
    }
  dump_field_lv (ctx, &out, symbol, &symbol->u.s.function, WEIGHT_NORMAL);
  dump_field_lv (ctx, &out, symbol, &symbol->u.s.plist, WEIGHT_NORMAL);
  dump_field_lv_rawptr (ctx, &out, symbol, &symbol->u.s.next, Lisp_Symbol,
                        WEIGHT_STRONG);

  offset = dump_object_finish (ctx, &out, sizeof (out));
  switch (symbol->u.s.redirect)
    {
    case SYMBOL_LOCALIZED:
      aux_offset = dump_recall_symbol_aux (ctx, make_lisp_symbol (symbol));
      dump_remember_fixup_ptr_raw (ctx, offset + dump_offsetof (struct Lisp_Symbol,
								u.s.val.blv),
				   (aux_offset
				    ? aux_offset
				    : dump_blv (ctx, symbol->u.s.val.blv)));
      break;
    case SYMBOL_FORWARDED:
      aux_offset = dump_recall_symbol_aux (ctx, make_lisp_symbol (symbol));
      /* Symbols interned by a defvar are not copied objects.  */
      if (!aux_offset)
	dump_fwd (ctx, symbol->u.s.val.fwd);
      if (aux_offset && (aux_offset
			 != emacs_offset (symbol->u.s.val.fwd.fwdptr)))
	emacs_abort ();
      break;
    default:
      break;
    }
  return offset;
}

static dump_off
dump_vectorlike_generic (struct dump_context *ctx,
			 const union vectorlike_header *header)
{
#if CHECK_STRUCTS && !defined (HASH_vectorlike_header_785E52047B)
# error "vectorlike_header changed. See CHECK_STRUCTS comment in config.h."
#endif
  const struct Lisp_Vector *v = (const struct Lisp_Vector *) header;
  ptrdiff_t size = header->size;
  enum pvec_type pvectype = PSEUDOVECTOR_TYPE (v);
  dump_off offset;

  if (size & PSEUDOVECTOR_FLAG)
    {
      /* Assert that the pseudovector contains only Lisp values ---
         but see the PVEC_SUB_CHAR_TABLE special case below.  We allow
         one extra word of non-lisp data when Lisp_Object is shorter
         than GCALIGN (e.g., on 32-bit builds) to account for
         GCALIGN-enforcing struct padding.  We can't distinguish
         between padding and some undumpable data member this way, but
         we'll count on sizeof(Lisp_Object) >= GCALIGN builds to catch
         this class of problem.
         */
      eassert ((size & PSEUDOVECTOR_REST_MASK) >> PSEUDOVECTOR_REST_BITS
	       <= (sizeof (Lisp_Object) < GCALIGNMENT));
      size &= PSEUDOVECTOR_SIZE_MASK;
    }

  dump_align_output (ctx, DUMP_ALIGNMENT);
  dump_off prefix_start_offset = ctx->offset;

  dump_off skip;
  if (pvectype == PVEC_SUB_CHAR_TABLE)
    {
      /* PVEC_SUB_CHAR_TABLE has a special case because it's a
         variable-length vector (unlike other pseudovectors, which is
         why we handle it here) and has its non-Lisp data _before_ the
         variable-length Lisp part.  */
      const struct Lisp_Sub_Char_Table *sct =
        (const struct Lisp_Sub_Char_Table *) header;
      struct Lisp_Sub_Char_Table out;
      /* Don't use sizeof(out), since that incorporates unwanted
         padding.  Instead, use the size through the last non-Lisp
         field.  */
      size_t sz = (char *)&out.min_char + sizeof (out.min_char) - (char *)&out;
      eassert (sz < DUMP_OFF_MAX);
      dump_object_start (ctx, &out, (dump_off) sz);
      DUMP_FIELD_COPY (&out, sct, header.size);
      DUMP_FIELD_COPY (&out, sct, depth);
      DUMP_FIELD_COPY (&out, sct, min_char);
      offset = dump_object_finish (ctx, &out, (dump_off) sz);
      skip = SUB_CHAR_TABLE_OFFSET;
    }
  else
    {
      union vectorlike_header out;
      dump_object_start (ctx, &out, sizeof (out));
      DUMP_FIELD_COPY (&out, header, size);
      offset = dump_object_finish (ctx, &out, sizeof (out));
      skip = 0;
    }

  /* We may have written a non-Lisp vector prefix above.  If we have,
     pad to the lisp content start with zero, and make sure we didn't
     scribble beyond that start.  */
  dump_off prefix_size = ctx->offset - prefix_start_offset;
  eassert (prefix_size > 0);
  dump_off skip_start = ptrdiff_t_to_dump_off ((char *) &v->contents[skip]
					       - (char *) v);
  eassert (skip_start >= prefix_size);
  dump_write_zero (ctx, skip_start - prefix_size);

  /* dump_object_start isn't what records conservative-GC object
     starts --- dump_object_1 does --- so the hack below of using
     dump_object_start for each vector word doesn't cause GC problems
     at runtime.  */
  struct dump_flags old_flags = ctx->flags;
  ctx->flags.pack_objects = true;
  for (dump_off i = skip; i < size; ++i)
    {
      Lisp_Object out;
      const Lisp_Object *vslot = &v->contents[i];
      /* In the wide case, we're always misaligned.  */
#if INTPTR_MAX == EMACS_INT_MAX
      eassert (ctx->offset % sizeof (out) == 0);
#endif
      dump_object_start (ctx, &out, sizeof (out));
      dump_field_lv (ctx, &out, vslot, vslot, WEIGHT_STRONG);
      dump_object_finish (ctx, &out, sizeof (out));
    }
  ctx->flags = old_flags;
  dump_align_output (ctx, DUMP_ALIGNMENT);
  return offset;
}

/* Return a vector of KEY, VALUE pairs in the given hash table H.
   No room for growth is included.  */
static Lisp_Object *
hash_table_contents (struct Lisp_Hash_Table *h)
{
  ptrdiff_t size = h->count;
  Lisp_Object *key_and_value = hash_table_alloc_bytes (2 * size
						       * sizeof *key_and_value);
  ptrdiff_t n = 0;

  DOHASH (h, k, v)
    {
      key_and_value[n++] = k;
      key_and_value[n++] = v;
    }

  return key_and_value;
}

static void
dump_hash_table_list (struct dump_context *ctx)
{
  if (!NILP (ctx->hash_tables))
    dump_object (ctx, CALLN (Fvconcat, ctx->hash_tables));
}

static hash_table_std_test_t
hash_table_std_test (const struct hash_table_test *t)
{
  if (BASE_EQ (t->name, Qeq))
    return Test_eq;
  if (BASE_EQ (t->name, Qeql))
    return Test_eql;
  if (BASE_EQ (t->name, Qequal))
    return Test_equal;
  error ("cannot dump hash tables with user-defined tests");  /* Bug#36769 */
}

/* Compact contents and discard inessential information from a hash table,
   preparing it for dumping.
   See `hash_table_thaw' for the code that restores the object to a usable
   state. */
static void
hash_table_freeze (struct Lisp_Hash_Table *h)
{
  h->key_and_value = hash_table_contents (h);
  h->next = NULL;
  h->hash = NULL;
  h->index = NULL;
  h->table_size = 0;
  h->index_bits = 0;
  h->frozen_test = hash_table_std_test (h->test);
  h->test = NULL;
}

static dump_off
dump_hash_table_contents (struct dump_context *ctx, struct Lisp_Hash_Table *h)
{
  dump_align_output (ctx, DUMP_ALIGNMENT);
  dump_off start_offset = ctx->offset;
  ptrdiff_t n = 2 * h->count;

  struct dump_flags old_flags = ctx->flags;
  ctx->flags.pack_objects = true;

  for (ptrdiff_t i = 0; i < n; i++)
    {
      Lisp_Object out;
      const Lisp_Object *slot = &h->key_and_value[i];
      dump_object_start (ctx, &out, sizeof out);
      dump_field_lv (ctx, &out, slot, slot, WEIGHT_STRONG);
      dump_object_finish (ctx, &out, sizeof out);
    }

  ctx->flags = old_flags;
  return start_offset;
}

static dump_off
dump_hash_table (struct dump_context *ctx, Lisp_Object object)
{
#if CHECK_STRUCTS && !defined HASH_Lisp_Hash_Table_2A3C3E2B62
# error "Lisp_Hash_Table changed. See CHECK_STRUCTS comment in config.h."
#endif
  const struct Lisp_Hash_Table *hash_in = XHASH_TABLE (object);
  struct Lisp_Hash_Table hash_munged = *hash_in;
  struct Lisp_Hash_Table *hash = &hash_munged;

  hash_table_freeze (hash);
  dump_push (&ctx->hash_tables, object);

  START_DUMP_PVEC (ctx, &hash->header, struct Lisp_Hash_Table, out);
  dump_pseudovector_lisp_fields (ctx, &out->header, &hash->header);
  DUMP_FIELD_COPY (out, hash, count);
  DUMP_FIELD_COPY (out, hash, weakness);
  DUMP_FIELD_COPY (out, hash, mutable);
  DUMP_FIELD_COPY (out, hash, frozen_test);
  if (hash->key_and_value)
    dump_field_fixup_later (ctx, out, hash, &hash->key_and_value);
  eassert (hash->next_weak == NULL);
  dump_off offset = finish_dump_pvec (ctx, &out->header);
  if (hash->key_and_value)
    dump_remember_fixup_ptr_raw
      (ctx,
       offset + dump_offsetof (struct Lisp_Hash_Table, key_and_value),
       dump_hash_table_contents (ctx, hash));
  return offset;
}

static dump_off
dump_obarray_buckets (struct dump_context *ctx, const struct Lisp_Obarray *o)
{
  dump_align_output (ctx, DUMP_ALIGNMENT);
  dump_off start_offset = ctx->offset;
  ptrdiff_t n = obarray_size (o);

  struct dump_flags old_flags = ctx->flags;
  ctx->flags.pack_objects = true;

  for (ptrdiff_t i = 0; i < n; i++)
    {
      Lisp_Object out;
      const Lisp_Object *slot = &o->buckets[i];
      dump_object_start (ctx, &out, sizeof out);
      dump_field_lv (ctx, &out, slot, slot, WEIGHT_STRONG);
      dump_object_finish (ctx, &out, sizeof out);
    }

  ctx->flags = old_flags;
  return start_offset;
}

static dump_off
dump_obarray (struct dump_context *ctx, Lisp_Object object)
{
#if CHECK_STRUCTS && !defined HASH_Lisp_Obarray_D2757E61AD
# error "Lisp_Obarray changed. See CHECK_STRUCTS comment in config.h."
#endif
  const struct Lisp_Obarray *in_oa = XOBARRAY (object);
  struct Lisp_Obarray munged_oa = *in_oa;
  struct Lisp_Obarray *oa = &munged_oa;
  START_DUMP_PVEC (ctx, &oa->header, struct Lisp_Obarray, out);
  dump_pseudovector_lisp_fields (ctx, &out->header, &oa->header);
  DUMP_FIELD_COPY (out, oa, count);
  DUMP_FIELD_COPY (out, oa, size_bits);
  dump_field_fixup_later (ctx, out, oa, &oa->buckets);
  dump_off offset = finish_dump_pvec (ctx, &out->header);
  dump_remember_fixup_ptr_raw
    (ctx,
     offset + dump_offsetof (struct Lisp_Obarray, buckets),
     dump_obarray_buckets (ctx, oa));
  return offset;
}

static dump_off
dump_buffer (struct dump_context *ctx, const struct buffer *in_buffer)
{
#if CHECK_STRUCTS && !defined HASH_buffer_E5E54A8C3F
# error "buffer changed. See CHECK_STRUCTS comment in config.h."
#endif
  struct buffer munged_buffer = *in_buffer;
  struct buffer *buffer = &munged_buffer;

  /* Clear some buffer state for correctness upon load.  */
  if (buffer->base_buffer == NULL)
    buffer->window_count = 0;
  else
    eassert (buffer->window_count == -1);
  buffer->local_minor_modes_ = Qnil;
  buffer->last_name_ = Qnil;
  buffer->last_selected_window_ = Qnil;
  buffer->display_count_ = make_fixnum (0);
  buffer->clip_changed = 0;
  buffer->last_window_start = -1;
  buffer->point_before_scroll_ = Qnil;

  dump_off base_offset = 0;
  if (buffer->base_buffer)
    {
      eassert (buffer->base_buffer->base_buffer == NULL);
      base_offset = dump_object_for_offset
	(ctx,
	 make_lisp_ptr (buffer->base_buffer, Lisp_Vectorlike));
    }

  eassert ((base_offset == 0 && buffer->text == &in_buffer->own_text)
	   || (base_offset > 0 && buffer->text != &in_buffer->own_text));

  START_DUMP_PVEC (ctx, &buffer->header, struct buffer, out);
  dump_pseudovector_lisp_fields (ctx, &out->header, &buffer->header);
  if (base_offset == 0)
    base_offset = ctx->obj_offset;
  eassert (base_offset > 0);
  if (buffer->base_buffer == NULL)
    {
      eassert (base_offset == ctx->obj_offset);

      if (BUFFER_LIVE_P (buffer))
        {
          dump_field_fixup_later (ctx, out, buffer, &buffer->own_text.beg);
	  dump_remember_cold_op (ctx, COLD_OP_BUFFER,
				 make_lisp_ptr ((void *) in_buffer,
						Lisp_Vectorlike));
        }
      else
        eassert (buffer->own_text.beg == NULL);

      DUMP_FIELD_COPY (out, buffer, own_text.gpt);
      DUMP_FIELD_COPY (out, buffer, own_text.z);
      DUMP_FIELD_COPY (out, buffer, own_text.gpt_byte);
      DUMP_FIELD_COPY (out, buffer, own_text.z_byte);
      DUMP_FIELD_COPY (out, buffer, own_text.gap_size);
      DUMP_FIELD_COPY (out, buffer, own_text.modiff);
      DUMP_FIELD_COPY (out, buffer, own_text.chars_modiff);
      DUMP_FIELD_COPY (out, buffer, own_text.save_modiff);
      DUMP_FIELD_COPY (out, buffer, own_text.overlay_modiff);
      DUMP_FIELD_COPY (out, buffer, own_text.compact);
      DUMP_FIELD_COPY (out, buffer, own_text.beg_unchanged);
      DUMP_FIELD_COPY (out, buffer, own_text.end_unchanged);
      DUMP_FIELD_COPY (out, buffer, own_text.unchanged_modified);
      DUMP_FIELD_COPY (out, buffer, own_text.overlay_unchanged_modified);
      if (buffer->own_text.intervals)
        dump_field_fixup_later (ctx, out, buffer, &buffer->own_text.intervals);
      dump_field_lv_rawptr (ctx, out, buffer, &buffer->own_text.markers,
                            Lisp_Vectorlike, WEIGHT_NORMAL);
      DUMP_FIELD_COPY (out, buffer, own_text.inhibit_shrinking);
      DUMP_FIELD_COPY (out, buffer, own_text.redisplay);
    }

  eassert (ctx->obj_offset > 0);
  dump_remember_fixup_ptr_raw
    (ctx,
     ctx->obj_offset + dump_offsetof (struct buffer, text),
     base_offset + dump_offsetof (struct buffer, own_text));

  DUMP_FIELD_COPY (out, buffer, pt);
  DUMP_FIELD_COPY (out, buffer, pt_byte);
  DUMP_FIELD_COPY (out, buffer, begv);
  DUMP_FIELD_COPY (out, buffer, begv_byte);
  DUMP_FIELD_COPY (out, buffer, zv);
  DUMP_FIELD_COPY (out, buffer, zv_byte);

  if (buffer->base_buffer)
    {
      eassert (ctx->obj_offset != base_offset);
      dump_field_ptr_to_dump_offset (ctx, out, buffer, &buffer->base_buffer,
				     base_offset);
    }

  DUMP_FIELD_COPY (out, buffer, indirections);
  DUMP_FIELD_COPY (out, buffer, window_count);

  memcpy (out->local_flags,
          &buffer->local_flags,
          sizeof (out->local_flags));
  DUMP_FIELD_COPY (out, buffer, modtime);
  DUMP_FIELD_COPY (out, buffer, modtime_size);
  DUMP_FIELD_COPY (out, buffer, auto_save_modified);
  DUMP_FIELD_COPY (out, buffer, display_error_modiff);
  DUMP_FIELD_COPY (out, buffer, auto_save_failure_time);
  DUMP_FIELD_COPY (out, buffer, last_window_start);

  /* Not worth serializing these caches.  TODO: really? */
  out->newline_cache = NULL;
  out->width_run_cache = NULL;
  out->bidi_paragraph_cache = NULL;

  DUMP_FIELD_COPY (out, buffer, prevent_redisplay_optimizations_p);
  DUMP_FIELD_COPY (out, buffer, clip_changed);
  DUMP_FIELD_COPY (out, buffer, inhibit_buffer_hooks);
  DUMP_FIELD_COPY (out, buffer, long_line_optimizations_p);

  if (!itree_empty_p (buffer->overlays))
    {
      /* We haven't implemented the code to dump overlays.  */
      error ("dumping overlays is not yet implemented");
    }
  else
    out->overlays = NULL;

  dump_field_lv (ctx, out, buffer, &buffer->undo_list_,
                 WEIGHT_STRONG);
  dump_off offset = finish_dump_pvec (ctx, &out->header);
  if (!buffer->base_buffer && buffer->own_text.intervals)
    dump_remember_fixup_ptr_raw
      (ctx,
       offset + dump_offsetof (struct buffer, own_text.intervals),
       dump_interval_tree (ctx, buffer->own_text.intervals, 0));

  return offset;
}

static dump_off
dump_bool_vector (struct dump_context *ctx, const struct Lisp_Vector *v)
{
#if CHECK_STRUCTS && !defined (HASH_Lisp_Vector_3091289B35)
# error "Lisp_Vector changed. See CHECK_STRUCTS comment in config.h."
#endif
  /* No relocation needed, so we don't need dump_object_start.  */
  dump_align_output (ctx, DUMP_ALIGNMENT);
  eassert (ctx->offset >= ctx->header.cold_start);
  dump_off offset = ctx->offset;
  ptrdiff_t nbytes = vector_nbytes ((struct Lisp_Vector *) v);
  if (nbytes > DUMP_OFF_MAX)
    error ("vector too large");
  dump_write (ctx, v, ptrdiff_t_to_dump_off (nbytes));
  return offset;
}

static dump_off
dump_subr (struct dump_context *ctx, const struct Lisp_Subr *subr)
{
#if CHECK_STRUCTS && !defined (HASH_Lisp_Subr_EE5F7351CC)
# error "Lisp_Subr changed. See CHECK_STRUCTS comment in config.h."
#endif
  struct Lisp_Subr out;
  dump_object_start (ctx, &out, sizeof (out));
  DUMP_FIELD_COPY (&out, subr, header.size);
#ifdef HAVE_NATIVE_COMP
  bool non_primitive = !NILP (subr->native_comp_u);
  if (non_primitive)
    out.function.a0 = NULL;
  else
#endif
    dump_field_emacs_ptr (ctx, &out, subr, &subr->function.a0);
  DUMP_FIELD_COPY (&out, subr, min_args);
  DUMP_FIELD_COPY (&out, subr, max_args);
#ifdef HAVE_NATIVE_COMP
  if (non_primitive)
    {
      dump_field_fixup_later (ctx, &out, subr, &subr->symbol_name);
      dump_remember_cold_op (ctx,
                             COLD_OP_NATIVE_SUBR,
			     make_lisp_ptr ((void *) subr, Lisp_Vectorlike));
      dump_field_lv (ctx, &out, subr, &subr->intspec.native, WEIGHT_NORMAL);
      dump_field_lv (ctx, &out, subr, &subr->command_modes, WEIGHT_NORMAL);
    }
  else
#endif
    {
      dump_field_emacs_ptr (ctx, &out, subr, &subr->symbol_name);
      dump_field_emacs_ptr (ctx, &out, subr, &subr->intspec.string);
      dump_field_emacs_ptr (ctx, &out, subr, &subr->command_modes);
    }
  DUMP_FIELD_COPY (&out, subr, doc);
#ifdef HAVE_NATIVE_COMP
  dump_field_lv (ctx, &out, subr, &subr->native_comp_u, WEIGHT_NORMAL);
  if (!NILP (subr->native_comp_u))
    dump_field_fixup_later (ctx, &out, subr, &subr->native_c_name);

  dump_field_lv (ctx, &out, subr, &subr->lambda_list, WEIGHT_NORMAL);
  dump_field_lv (ctx, &out, subr, &subr->type, WEIGHT_NORMAL);
#endif
  dump_off subr_off = dump_object_finish (ctx, &out, sizeof (out));
#ifdef HAVE_NATIVE_COMP
  if (non_primitive && ctx->flags.dump_object_contents)
    /* We'll do the final addr relocation during VERY_LATE_RELOCS time
       after the compilation units has been loaded. */
    dump_push (&ctx->dump_relocs[VERY_LATE_RELOCS],
	       list2 (make_fixnum (RELOC_NATIVE_SUBR),
		      dump_off_to_lisp (subr_off)));
#endif
  return subr_off;
}

#ifdef HAVE_NATIVE_COMP
static dump_off
dump_native_comp_unit (struct dump_context *ctx,
		       struct Lisp_Native_Comp_Unit *comp_u)
{
  if (!CONSP (comp_u->file))
    error ("trying to dump non fixed-up eln file");

  /* Have function documentation always lazy loaded to optimize load-time.  */
  comp_u->data_fdoc_v = Qnil;
  START_DUMP_PVEC (ctx, &comp_u->header, struct Lisp_Native_Comp_Unit, out);
  dump_pseudovector_lisp_fields (ctx, &out->header, &comp_u->header);
  out->handle = NULL;

  dump_off comp_u_off = finish_dump_pvec (ctx, &out->header);
  if (ctx->flags.dump_object_contents)
    /* We'll do the real elf load during LATE_RELOCS relocation time. */
    dump_push (&ctx->dump_relocs[LATE_RELOCS],
	       list2 (make_fixnum (RELOC_NATIVE_COMP_UNIT),
		      dump_off_to_lisp (comp_u_off)));
  return comp_u_off;
}
#endif

static void
fill_pseudovec (union vectorlike_header *header, Lisp_Object item)
{
  struct Lisp_Vector *v = (struct Lisp_Vector *) header;
  eassert (v->header.size & PSEUDOVECTOR_FLAG);
  ptrdiff_t size = v->header.size & PSEUDOVECTOR_SIZE_MASK;
  for (ptrdiff_t idx = 0; idx < size; idx++)
    v->contents[idx] = item;
}

static dump_off
dump_nilled_pseudovec (struct dump_context *ctx,
                       const union vectorlike_header *in)
{
  START_DUMP_PVEC (ctx, in, struct Lisp_Vector, out);
  fill_pseudovec (&out->header, Qnil);
  return finish_dump_pvec (ctx, &out->header);
}

static dump_off
dump_vectorlike (struct dump_context *ctx,
                 Lisp_Object lv,
                 dump_off offset)
{
#if CHECK_STRUCTS && !defined HASH_pvec_type_99104541E2
# error "pvec_type changed. See CHECK_STRUCTS comment in config.h."
#endif
  const struct Lisp_Vector *v = XVECTOR (lv);
  enum pvec_type ptype = PSEUDOVECTOR_TYPE (v);
  switch (ptype)
    {
    case PVEC_FONT:
      /* There are three kinds of font objects that all use PVEC_FONT,
         distinguished by their size.  Font specs and entities are
         harmless data carriers that we can dump like other Lisp
         objects.  Fonts themselves are window-system-specific and
         need to be recreated on each startup.  */
      if ((v->header.size & PSEUDOVECTOR_SIZE_MASK) != FONT_SPEC_MAX
	  && (v->header.size & PSEUDOVECTOR_SIZE_MASK) != FONT_ENTITY_MAX)
        error_unsupported_dump_object(ctx, lv, "font");
      FALLTHROUGH;
    case PVEC_NORMAL_VECTOR:
    case PVEC_CLOSURE:
    case PVEC_CHAR_TABLE:
    case PVEC_SUB_CHAR_TABLE:
    case PVEC_RECORD:
      return dump_vectorlike_generic (ctx, &v->header);
    case PVEC_BOOL_VECTOR:
      return dump_bool_vector(ctx, v);
    case PVEC_HASH_TABLE:
      return dump_hash_table (ctx, lv);
    case PVEC_OBARRAY:
      return dump_obarray (ctx, lv);
    case PVEC_BUFFER:
      return dump_buffer (ctx, XBUFFER (lv));
    case PVEC_SUBR:
      return dump_subr (ctx, XSUBR (lv));
    case PVEC_FRAME:
    case PVEC_WINDOW:
    case PVEC_PROCESS:
    case PVEC_TERMINAL:
      return dump_nilled_pseudovec (ctx, &v->header);
    case PVEC_MARKER:
      return dump_marker (ctx, XMARKER (lv));
    case PVEC_OVERLAY:
      return dump_overlay (ctx, XOVERLAY (lv));
    case PVEC_FINALIZER:
      return dump_finalizer (ctx, XFINALIZER (lv));
    case PVEC_BIGNUM:
      return dump_bignum (ctx, lv);
    case PVEC_NATIVE_COMP_UNIT:
#ifdef HAVE_NATIVE_COMP
      return dump_native_comp_unit (ctx, XNATIVE_COMP_UNIT (lv));
#endif
      break;
    case PVEC_THREAD:
      if (main_thread_p (v))
        {
          eassert (dump_object_emacs_ptr (lv));
          return DUMP_OBJECT_IS_RUNTIME_MAGIC;
        }
      break;
    case PVEC_TS_COMPILED_QUERY:
#ifdef HAVE_TREE_SITTER
      return dump_treesit_compiled_query (ctx, XTS_COMPILED_QUERY (lv));
#endif
    case PVEC_WINDOW_CONFIGURATION:
    case PVEC_OTHER:
    case PVEC_XWIDGET:
    case PVEC_XWIDGET_VIEW:
    case PVEC_MISC_PTR:
    case PVEC_USER_PTR:
    case PVEC_MUTEX:
    case PVEC_CONDVAR:
    case PVEC_SQLITE:
    case PVEC_MODULE_FUNCTION:
    case PVEC_SYMBOL_WITH_POS:
    case PVEC_FREE:
    case PVEC_TS_PARSER:
    case PVEC_TS_NODE:
      break;
    }
  int iptype = ptype;
  static char const fmt[] = "pseudovector type %d";
  char msg[sizeof fmt - sizeof "%d" + INT_STRLEN_BOUND (iptype) + 1];
  sprintf (msg, fmt, iptype);
  error_unsupported_dump_object (ctx, lv, msg);
}

/* Add an object to the dump.

   CTX is the dump context; OBJECT is the object to add.  Normally,
   return OFFSET, the location (in bytes, from the start of the dump
   file) where we wrote the object.  Valid OFFSETs are always greater
   than zero.

   If we've already dumped an object, return the location where we put
   it: dump_object is idempotent.

   The object must refer to an actual pointer-ish object of some sort.
   Some self-representing objects are immediate values rather than
   tagged pointers to Lisp heap structures and so have no individual
   representation in the Lisp heap dump.

   May also return one of the DUMP_OBJECT_ON_*_QUEUE constants if we
   "dumped" the object by remembering to process it specially later.
   In this case, we don't have a valid offset.
   Call dump_object_for_offset if you need a valid offset for
   an object.
 */
static dump_off
dump_object (struct dump_context *ctx, Lisp_Object object)
{
#if CHECK_STRUCTS && !defined (HASH_Lisp_Type_45F0582FD7)
# error "Lisp_Type changed. See CHECK_STRUCTS comment in config.h."
#endif
  eassert (!EQ (object, dead_object ()));

  dump_off offset = dump_recall_object (ctx, object);
  if (offset > 0)
    return offset;  /* Object already dumped.  */

  bool cold = BOOL_VECTOR_P (object) || FLOATP (object);
  if (cold && ctx->flags.defer_cold_objects)
    {
      if (offset != DUMP_OBJECT_ON_COLD_QUEUE)
        {
	  eassert (offset == DUMP_OBJECT_ON_NORMAL_QUEUE
		   || offset == DUMP_OBJECT_NOT_SEEN);
          offset = DUMP_OBJECT_ON_COLD_QUEUE;
          dump_remember_object (ctx, object, offset);
          dump_remember_cold_op (ctx, COLD_OP_OBJECT, object);
        }
      return offset;
    }

  void *obj_in_emacs = dump_object_emacs_ptr (object);
  if (obj_in_emacs && ctx->flags.defer_copied_objects)
    {
      if (offset != DUMP_OBJECT_ON_COPIED_QUEUE)
        {
	  eassert (offset == DUMP_OBJECT_ON_NORMAL_QUEUE
		   || offset == DUMP_OBJECT_NOT_SEEN);
          /* Even though we're not going to dump this object right
             away, we still want to scan and enqueue its
             referents.  */
          struct dump_flags old_flags = ctx->flags;
          ctx->flags.dump_object_contents = false;
          ctx->flags.defer_copied_objects = false;
          dump_object (ctx, object);
          ctx->flags = old_flags;

          offset = DUMP_OBJECT_ON_COPIED_QUEUE;
          dump_remember_object (ctx, object, offset);
          dump_push (&ctx->copied_queue, object);
        }
      return offset;
    }

  /* Object needs to be dumped.  */
  if (dump_set_referrer (ctx))
    ctx->current_referrer = object;
  switch (XTYPE (object))
    {
    case Lisp_String:
      offset = dump_string (ctx, XSTRING (object));
      break;
    case Lisp_Vectorlike:
      offset = dump_vectorlike (ctx, object, offset);
      break;
    case Lisp_Symbol:
      offset = dump_symbol (ctx, object, offset);
      break;
    case Lisp_Cons:
      offset = dump_cons (ctx, XCONS (object));
      break;
    case Lisp_Float:
      offset = dump_float (ctx, XFLOAT (object));
      break;
    case Lisp_Int0:
    case Lisp_Int1:
      eassert ("should not be dumping int: is self-representing" && 0);
      abort ();
    default:
      emacs_abort ();
    }
  dump_clear_referrer (ctx);

  /* offset can be < 0 if we've deferred an object.  */
  if (ctx->flags.dump_object_contents && offset > DUMP_OBJECT_NOT_SEEN)
    {
      eassert (offset % DUMP_ALIGNMENT == 0);
      dump_remember_object (ctx, object, offset);
      if (ctx->flags.record_object_starts)
        {
          eassert (!ctx->flags.pack_objects);
          dump_push (&ctx->object_starts,
                     list2 (dump_off_to_lisp (XTYPE (object)),
                            dump_off_to_lisp (offset)));
        }
    }

  return offset;
}

/* Like dump_object(), but assert that we get a valid offset.  */
static dump_off
dump_object_for_offset (struct dump_context *ctx, Lisp_Object object)
{
  dump_off offset = dump_object (ctx, object);
  eassert (offset > 0);
  return offset;
}

static dump_off
dump_charset (struct dump_context *ctx, int cs_i)
{
#if CHECK_STRUCTS && !defined (HASH_charset_E31F4B5D96)
# error "charset changed. See CHECK_STRUCTS comment in config.h."
#endif
  /* We can't change the alignment here, because ctx->offset is what
     will be used for the whole array.  */
  eassert (ctx->offset % alignof (struct charset) == 0);
  const struct charset *cs = charset_table + cs_i;
  struct charset out;
  dump_object_start (ctx, &out, sizeof (out));
  if (cs_i < charset_table_used) /* Don't look at uninitialized data.  */
    {
      DUMP_FIELD_COPY (&out, cs, id);
      dump_field_lv (ctx, &out, cs, &cs->attributes, WEIGHT_NORMAL);
      DUMP_FIELD_COPY (&out, cs, dimension);
      memcpy (out.code_space, &cs->code_space, sizeof (cs->code_space));
      if (cs->code_space_mask)
        dump_field_fixup_later (ctx, &out, cs, &cs->code_space_mask);
      DUMP_FIELD_COPY (&out, cs, code_linear_p);
      DUMP_FIELD_COPY (&out, cs, iso_chars_96);
      DUMP_FIELD_COPY (&out, cs, ascii_compatible_p);
      DUMP_FIELD_COPY (&out, cs, supplementary_p);
      DUMP_FIELD_COPY (&out, cs, compact_codes_p);
      DUMP_FIELD_COPY (&out, cs, unified_p);
      DUMP_FIELD_COPY (&out, cs, iso_final);
      DUMP_FIELD_COPY (&out, cs, iso_revision);
      DUMP_FIELD_COPY (&out, cs, emacs_mule_id);
      DUMP_FIELD_COPY (&out, cs, method);
      DUMP_FIELD_COPY (&out, cs, min_code);
      DUMP_FIELD_COPY (&out, cs, max_code);
      DUMP_FIELD_COPY (&out, cs, char_index_offset);
      DUMP_FIELD_COPY (&out, cs, min_char);
      DUMP_FIELD_COPY (&out, cs, max_char);
      DUMP_FIELD_COPY (&out, cs, invalid_code);
      memcpy (out.fast_map, &cs->fast_map, sizeof (cs->fast_map));
      DUMP_FIELD_COPY (&out, cs, code_offset);
    }
  dump_off offset = dump_object_finish (ctx, &out, sizeof (out));
  if (cs_i < charset_table_used && cs->code_space_mask)
    dump_remember_cold_op (ctx, COLD_OP_CHARSET,
                           Fcons (dump_off_to_lisp (cs_i),
                                  dump_off_to_lisp (offset)));
  return offset;
}

static dump_off
dump_charset_table (struct dump_context *ctx)
{
  struct dump_flags old_flags = ctx->flags;
  ctx->flags.pack_objects = true;
  dump_align_output (ctx, alignof (struct charset));
  dump_off offset = ctx->offset;
  if (dump_set_referrer (ctx))
    ctx->current_referrer = build_string ("charset_table");
  /* We are dumping the entire table, not just the used slots, because
     otherwise when we restore from the pdump file, the actual size of
     the table will be smaller than charset_table_size, and we will
     crash if/when a new charset is defined.  */
  for (int i = 0; i < charset_table_size; ++i)
    dump_charset (ctx, i);
  dump_clear_referrer (ctx);
  dump_emacs_reloc_to_dump_ptr_raw (ctx, &charset_table, offset);
  ctx->flags = old_flags;
  return offset;
}

static void
dump_finalizer_list_head_ptr (struct dump_context *ctx,
                              struct Lisp_Finalizer **ptr)
{
  struct Lisp_Finalizer *value = *ptr;
  if (value != &finalizers && value != &doomed_finalizers)
    dump_emacs_reloc_to_dump_ptr_raw
      (ctx, ptr,
       dump_object_for_offset (ctx,
			       make_lisp_ptr (value, Lisp_Vectorlike)));
}

static void
dump_metadata_for_pdumper (struct dump_context *ctx)
{
  for (int i = 0; i < nr_dump_hooks; ++i)
    dump_emacs_reloc_to_emacs_ptr_raw (ctx, &dump_hooks[i],
				       (void const *) dump_hooks[i]);
  dump_emacs_reloc_immediate_int (ctx, &nr_dump_hooks, nr_dump_hooks);

  for (int i = 0; i < nr_dump_late_hooks; ++i)
    dump_emacs_reloc_to_emacs_ptr_raw (ctx, &dump_late_hooks[i],
				       (void const *) dump_late_hooks[i]);
  dump_emacs_reloc_immediate_int (ctx, &nr_dump_late_hooks,
				  nr_dump_late_hooks);

  for (int i = 0; i < nr_remembered_data; ++i)
    {
      dump_emacs_reloc_to_emacs_ptr_raw (ctx, &remembered_data[i].mem,
					 remembered_data[i].mem);
      dump_emacs_reloc_immediate_int (ctx, &remembered_data[i].sz,
				      remembered_data[i].sz);
    }
  dump_emacs_reloc_immediate_int (ctx, &nr_remembered_data,
				  nr_remembered_data);
}

/* Sort the list of copied objects in CTX.  */
static void
dump_sort_copied_objects (struct dump_context *ctx)
{
  Lisp_Object queue_reversed;

  queue_reversed = Fnreverse (ctx->copied_queue);
  /* Sort the objects into the order in which they'll appear in the
     Emacs: this way, on startup, we'll do both the IO from the dump
     file and the copy into Emacs in-order, where prefetch will be
     most effective.  */
  ctx->copied_queue
    = CALLN (Fsort, queue_reversed,
	     Qdump_emacs_portable__sort_predicate_copied);
}

/* Dump parts of copied objects we need at runtime.  */
static void
dump_hot_parts_of_discardable_objects (struct dump_context *ctx)
{
  Lisp_Object copied_queue = ctx->copied_queue;
  while (!NILP (copied_queue))
    {
      Lisp_Object copied = dump_pop (&copied_queue);
      if (SYMBOLP (copied))
        {
          eassert (dump_builtin_symbol_p (copied));
          dump_pre_dump_symbol (ctx, XSYMBOL (copied));
        }
    }
}

static void
dump_drain_copied_objects (struct dump_context *ctx)
{
  Lisp_Object copied_queue = ctx->copied_queue;
  ctx->copied_queue = Qnil;

  struct dump_flags old_flags = ctx->flags;

  /* We should have already fully scanned these objects, so assert
     that we're not adding more entries to the dump queue.  */
  ctx->flags.assert_already_seen = true;

  /* Now we want to actually dump the copied objects, not just record
     them.  */
  ctx->flags.defer_copied_objects = false;

  /* Objects that we memcpy into Emacs shouldn't get object-start
     records (which conservative GC looks at): we usually discard this
     memory after we're finished memcpying, and even if we don't, the
     "real" objects in this section all live in the Emacs image, not
     in the dump.  */
  ctx->flags.record_object_starts = false;

  /* Dump the objects and generate a copy relocation for each.  Don't
     bother trying to reduce the number of copy relocations we
     generate: we'll merge adjacent copy relocations upon output.
     The overall result is that to the greatest extent possible while
     maintaining strictly increasing address order, we copy into Emacs
     in nice big chunks.  */
  while (!NILP (copied_queue))
    {
      Lisp_Object copied = dump_pop (&copied_queue);
      void *optr = dump_object_emacs_ptr (copied);
      eassert (optr != NULL);
      /* N.B. start_offset is beyond any padding we insert.  */
      dump_off start_offset = dump_object (ctx, copied);
      if (start_offset != DUMP_OBJECT_IS_RUNTIME_MAGIC)
        {
          dump_off size = ctx->offset - start_offset;
          dump_emacs_reloc_copy_from_dump (ctx, start_offset, optr, size);
        }
    }

  ctx->flags = old_flags;
}

static void
dump_cold_string (struct dump_context *ctx, Lisp_Object string)
{
  /* Dump string contents.  */
  dump_off string_offset = dump_recall_object (ctx, string);
  eassert (string_offset > 0);
  if (SBYTES (string) > DUMP_OFF_MAX - 1)
    error ("string too large");
  dump_off total_size = ptrdiff_t_to_dump_off (SBYTES (string) + 1);
  eassert (total_size > 0);
  dump_remember_fixup_ptr_raw
    (ctx,
     string_offset + dump_offsetof (struct Lisp_String, u.s.data),
     ctx->offset);
  dump_write (ctx, XSTRING (string)->u.s.data, total_size);
}

static void
dump_cold_charset (struct dump_context *ctx, Lisp_Object data)
{
  /* Dump charset lookup tables.  */
  int cs_i = XFIXNUM (XCAR (data));
  dump_off cs_dump_offset = dump_off_from_lisp (XCDR (data));
  dump_remember_fixup_ptr_raw
    (ctx,
     cs_dump_offset + dump_offsetof (struct charset, code_space_mask),
     ctx->offset);
  struct charset *cs = charset_table + cs_i;
  dump_write (ctx, cs->code_space_mask, 256);
}

static void
dump_cold_buffer (struct dump_context *ctx, Lisp_Object data)
{
  /* Dump buffer text.  */
  dump_off buffer_offset = dump_recall_object (ctx, data);
  eassert (buffer_offset > 0);
  struct buffer *b = XBUFFER (data);
  eassert (b->text == &b->own_text);
  /* Zero the gap so we don't dump uninitialized bytes.  */
  memset (BUF_GPT_ADDR (b), 0, BUF_GAP_SIZE (b));
  /* See buffer.c for this calculation.  */
  ptrdiff_t nbytes =
    BUF_Z_BYTE (b)
    - BUF_BEG_BYTE (b)
    + BUF_GAP_SIZE (b)
    + 1;
  if (nbytes > DUMP_OFF_MAX)
    error ("buffer too large");
  dump_remember_fixup_ptr_raw
    (ctx,
     buffer_offset + dump_offsetof (struct buffer, own_text.beg),
     ctx->offset);
  dump_write (ctx, b->own_text.beg, ptrdiff_t_to_dump_off (nbytes));
}

static void
dump_cold_bignum (struct dump_context *ctx, Lisp_Object object)
{
  mpz_t const *n = xbignum_val (object);
  size_t sz_nlimbs = mpz_size (*n);
  eassert (sz_nlimbs < DUMP_OFF_MAX);
  dump_align_output (ctx, alignof (mp_limb_t));
  dump_off nlimbs = (dump_off) sz_nlimbs;
  Lisp_Object descriptor
    = list2 (dump_off_to_lisp (ctx->offset),
	     dump_off_to_lisp (mpz_sgn (*n) < 0 ? -nlimbs : nlimbs));
  Fputhash (object, descriptor, ctx->bignum_data);
  for (mp_size_t i = 0; i < nlimbs; ++i)
    {
      mp_limb_t limb = mpz_getlimbn (*n, i);
      dump_write (ctx, &limb, sizeof (limb));
    }
}

#ifdef HAVE_NATIVE_COMP
static void
dump_cold_native_subr (struct dump_context *ctx, Lisp_Object subr)
{
  /* Dump subr contents.  */
  dump_off subr_offset = dump_recall_object (ctx, subr);
  eassert (subr_offset > 0);
  dump_remember_fixup_ptr_raw
    (ctx,
     subr_offset + dump_offsetof (struct Lisp_Subr, symbol_name),
     ctx->offset);
  const char *symbol_name = XSUBR (subr)->symbol_name;
  dump_write (ctx, symbol_name, 1 + strlen (symbol_name));

  dump_remember_fixup_ptr_raw
    (ctx,
     subr_offset + dump_offsetof (struct Lisp_Subr, native_c_name),
     ctx->offset);
  const char *c_name = XSUBR (subr)->native_c_name;
  dump_write (ctx, c_name, 1 + strlen (c_name));
}
#endif

static void
dump_drain_cold_data (struct dump_context *ctx)
{
  Lisp_Object cold_queue = Fnreverse (ctx->cold_queue);
  ctx->cold_queue = Qnil;

  struct dump_flags old_flags = ctx->flags;

  /* We should have already scanned all objects to which our cold
     objects refer, so die if an object points to something we haven't
     seen.  */
  ctx->flags.assert_already_seen = true;

  /* Actually dump cold objects instead of deferring them.  */
  ctx->flags.defer_cold_objects = false;

  while (!NILP (cold_queue))
    {
      Lisp_Object item = dump_pop (&cold_queue);
      enum cold_op op = (enum cold_op) XFIXNUM (XCAR (item));
      Lisp_Object data = XCDR (item);
      switch (op)
        {
        case COLD_OP_STRING:
          dump_cold_string (ctx, data);
          break;
        case COLD_OP_CHARSET:
          dump_cold_charset (ctx, data);
          break;
        case COLD_OP_BUFFER:
          dump_cold_buffer (ctx, data);
          break;
        case COLD_OP_OBJECT:
          /* Objects that we can put in the cold section
             must not refer to other objects.  */
          eassert (dump_queue_empty_p (&ctx->dump_queue));
          eassert (ctx->flags.dump_object_contents);
          dump_object (ctx, data);
          eassert (dump_queue_empty_p (&ctx->dump_queue));
          break;
        case COLD_OP_BIGNUM:
          dump_cold_bignum (ctx, data);
          break;
#ifdef HAVE_NATIVE_COMP
	case COLD_OP_NATIVE_SUBR:
	  dump_cold_native_subr (ctx, data);
	  break;
#endif
        default:
          emacs_abort ();
        }
    }

  ctx->flags = old_flags;
}

static void
read_ptr_raw_and_lv (const void *mem,
                     enum Lisp_Type type,
                     void **out_ptr,
                     Lisp_Object *out_lv)
{
  memcpy (out_ptr, mem, sizeof (*out_ptr));
  if (*out_ptr != NULL)
    {
      switch (type)
        {
        case Lisp_Symbol:
          *out_lv = make_lisp_symbol (*out_ptr);
          break;
        case Lisp_String:
        case Lisp_Vectorlike:
        case Lisp_Cons:
        case Lisp_Float:
          *out_lv = make_lisp_ptr (*out_ptr, type);
          break;
        default:
          emacs_abort ();
        }
    }
}

/* Enqueue for dumping objects referenced by static non-Lisp_Object
   pointers inside Emacs.  */
static void
dump_drain_user_remembered_data_hot (struct dump_context *ctx)
{
  for (int i = 0; i < nr_remembered_data; ++i)
    {
      void *mem = remembered_data[i].mem;
      int sz = remembered_data[i].sz;
      if (sz <= 0)
        {
          enum Lisp_Type type = -sz;
          void *value;
          Lisp_Object lv;
          read_ptr_raw_and_lv (mem, type, &value, &lv);
          if (value != NULL)
            {
	      if (dump_set_referrer (ctx))
		ctx->current_referrer = dump_ptr_referrer ("user data", mem);
              dump_enqueue_object (ctx, lv, WEIGHT_NONE);
	      dump_clear_referrer (ctx);
            }
        }
    }
}

/* Dump user-specified non-relocated data.  */
static void
dump_drain_user_remembered_data_cold (struct dump_context *ctx)
{
  for (int i = 0; i < nr_remembered_data; ++i)
    {
      void *mem = remembered_data[i].mem;
      int sz = remembered_data[i].sz;
      if (sz > 0)
        {
          /* Scalar: try to inline the value into the relocation if
             it's small enough; if it's bigger than we can fit in a
             relocation, we have to copy the data into the dump proper
             and emit a copy relocation.  */
          if (sz <= sizeof (intmax_t))
            dump_emacs_reloc_immediate (ctx, mem, mem, sz);
          else
            {
              dump_emacs_reloc_copy_from_dump (ctx, ctx->offset, mem, sz);
              dump_write (ctx, mem, sz);
            }
        }
      else
        {
          /* *mem is a raw pointer to a Lisp object of some sort.
             The object to which it points should have already been
             dumped by dump_drain_user_remembered_data_hot.  */
          void *value;
          Lisp_Object lv;
          enum Lisp_Type type = -sz;
          read_ptr_raw_and_lv (mem, type, &value, &lv);
          if (value == NULL)
            /* We can't just ignore NULL: the variable might have
               transitioned from non-NULL to NULL, and we want to
               record this fact.  */
            dump_emacs_reloc_immediate_ptrdiff_t (ctx, mem, 0);
          else
            {
              if (dump_object_emacs_ptr (lv) != NULL)
                {
                  /* We have situation like this:

                     static Lisp_Symbol *foo;
                     ...
                     foo = XSYMBOL(Qt);
                     ...
                     pdumper_remember_lv_ptr_raw (&foo, Lisp_Symbol);

                     Built-in symbols like Qt aren't in the dump!
                     They're actually in Emacs proper.  We need a
                     special case to point this value back at Emacs
                     instead of to something in the dump that
                     isn't there.

                     An analogous situation applies to subrs, since
                     Lisp_Subr structures always live in Emacs, not
                     the dump.
                  */
		  dump_emacs_reloc_to_emacs_ptr_raw
		    (ctx, mem, dump_object_emacs_ptr (lv));
                }
              else
                {
                  eassert (!dump_object_self_representing_p (lv));
                  dump_off dump_offset = dump_recall_object (ctx, lv);
                  if (dump_offset <= 0)
                    error ("raw-pointer object not dumped?!");
                  dump_emacs_reloc_to_dump_ptr_raw (ctx, mem, dump_offset);
                }
            }
        }
    }
}

static void
dump_unwind_cleanup (void *data)
{
  struct dump_context *ctx = data;
  if (ctx->fd >= 0)
    emacs_close (ctx->fd);
#ifdef REL_ALLOC
  if (ctx->blocked_ralloc)
    r_alloc_inhibit_buffer_relocation (0);
#endif
  Vpurify_flag = ctx->old_purify_flag;
  Vpost_gc_hook = ctx->old_post_gc_hook;
  Vprocess_environment = ctx->old_process_environment;
}

/* Check that DUMP_OFFSET is within the heap.  */
static void
dump_check_dump_off (struct dump_context *ctx, dump_off dump_offset)
{
  eassert (dump_offset > 0);
  eassert (!ctx || dump_offset < ctx->end_heap);
}

static void
dump_check_emacs_off (dump_off emacs_off)
{
  eassert (labs (emacs_off) <= 60 * 1024 * 1024);
}

static struct dump_reloc
dump_decode_dump_reloc (Lisp_Object lreloc)
{
  struct dump_reloc reloc;
  dump_reloc_set_type (&reloc,
		       (enum dump_reloc_type) XFIXNUM (dump_pop (&lreloc)));
  eassert (reloc.type <= RELOC_DUMP_TO_EMACS_LV + Lisp_Float);
  dump_reloc_set_offset (&reloc, dump_off_from_lisp (dump_pop (&lreloc)));
  eassert (NILP (lreloc));
  return reloc;
}

static void
dump_emit_dump_reloc (struct dump_context *ctx, Lisp_Object lreloc)
{
  eassert (ctx->flags.pack_objects);
  struct dump_reloc reloc;
  dump_object_start (ctx, &reloc, sizeof (reloc));
  reloc = dump_decode_dump_reloc (lreloc);
  dump_check_dump_off (ctx, dump_reloc_get_offset (reloc));
  dump_object_finish (ctx, &reloc, sizeof (reloc));
  if (dump_reloc_get_offset (reloc) < ctx->header.discardable_start)
    ctx->number_hot_relocations += 1;
  else
    ctx->number_discardable_relocations += 1;
}

#ifdef ENABLE_CHECKING
static Lisp_Object
dump_check_overlap_dump_reloc (Lisp_Object lreloc_a,
                               Lisp_Object lreloc_b)
{
  struct dump_reloc reloc_a = dump_decode_dump_reloc (lreloc_a);
  struct dump_reloc reloc_b = dump_decode_dump_reloc (lreloc_b);
  eassert (dump_reloc_get_offset (reloc_a) < dump_reloc_get_offset (reloc_b));
  return Qnil;
}
#endif

/* Translate a Lisp Emacs-relocation descriptor (a list whose first
   element is one of the EMACS_RELOC_* values, encoded as a fixnum)
   into an emacs_reloc structure value suitable for writing to the
   dump file.
*/
static struct emacs_reloc
decode_emacs_reloc (struct dump_context *ctx, Lisp_Object lreloc)
{
  struct emacs_reloc reloc = {0};
  int type = XFIXNUM (dump_pop (&lreloc));
  reloc.emacs_offset = dump_off_from_lisp (dump_pop (&lreloc));
  dump_check_emacs_off (reloc.emacs_offset);
  switch (type)
    {
    case RELOC_EMACS_COPY_FROM_DUMP:
      {
        emacs_reloc_set_type (&reloc, type);
        reloc.u.dump_offset = dump_off_from_lisp (dump_pop (&lreloc));
        dump_check_dump_off (ctx, reloc.u.dump_offset);
        dump_off length = dump_off_from_lisp (dump_pop (&lreloc));
        reloc.length = length;
        if (reloc.length != length)
          error ("relocation copy length too large");
      }
      break;
    case RELOC_EMACS_IMMEDIATE:
      {
        emacs_reloc_set_type (&reloc, type);
        intmax_t value = intmax_t_from_lisp (dump_pop (&lreloc));
        dump_off size = dump_off_from_lisp (dump_pop (&lreloc));
        reloc.u.immediate = value;
        reloc.length = size;
        eassert (reloc.length == size);
      }
      break;
    case RELOC_EMACS_EMACS_PTR_RAW:
      emacs_reloc_set_type (&reloc, type);
      reloc.u.emacs_offset2 = dump_off_from_lisp (dump_pop (&lreloc));
      dump_check_emacs_off (reloc.u.emacs_offset2);
      break;
    case RELOC_EMACS_DUMP_PTR_RAW:
      emacs_reloc_set_type (&reloc, type);
      reloc.u.dump_offset = dump_off_from_lisp (dump_pop (&lreloc));
      dump_check_dump_off (ctx, reloc.u.dump_offset);
      break;
    case RELOC_EMACS_DUMP_LV:
    case RELOC_EMACS_EMACS_LV:
      {
        emacs_reloc_set_type (&reloc, type);
        Lisp_Object target_value = dump_pop (&lreloc);
        /* If the object is self-representing,
           dump_emacs_reloc_to_lv didn't do its job.
           dump_emacs_reloc_to_lv should have added a
           RELOC_EMACS_IMMEDIATE relocation instead.  */
        eassert (!dump_object_self_representing_p (target_value));
        int tag_type = XTYPE (target_value);
        reloc.length = tag_type;
        eassert (reloc.length == tag_type);

        if (type == RELOC_EMACS_EMACS_LV)
          {
            void *obj_in_emacs = dump_object_emacs_ptr (target_value);
            eassert (obj_in_emacs);
            reloc.u.emacs_offset2 = emacs_offset (obj_in_emacs);
          }
        else
          {
	    eassume (ctx); /* Pacify GCC 9.2.1 -O3 -Wnull-dereference.  */
            eassert (!dump_object_emacs_ptr (target_value));
            reloc.u.dump_offset = dump_recall_object (ctx, target_value);
            if (reloc.u.dump_offset <= 0)
              {
                Lisp_Object repr = Fprin1_to_string (target_value, Qnil, Qnil);
                error ("relocation target was not dumped: %s", SDATA (repr));
              }
            dump_check_dump_off (ctx, reloc.u.dump_offset);
          }
      }
      break;
    default:
      eassume (!"not reached");
    }

  /* We should have consumed the whole relocation descriptor.  */
  eassert (NILP (lreloc));

  return reloc;
}

static void
dump_emit_emacs_reloc (struct dump_context *ctx, Lisp_Object lreloc)
{
  eassert (ctx->flags.pack_objects);
  struct emacs_reloc reloc;
  dump_object_start (ctx, &reloc, sizeof (reloc));
  reloc = decode_emacs_reloc (ctx, lreloc);
  dump_object_finish (ctx, &reloc, sizeof (reloc));
}

static Lisp_Object
dump_merge_emacs_relocs (Lisp_Object lreloc_a, Lisp_Object lreloc_b)
{
  /* Combine copy relocations together if they're copying from
     adjacent chunks to adjacent chunks.  */

#ifdef ENABLE_CHECKING
  {
    dump_off off_a = dump_off_from_lisp (XCAR (XCDR (lreloc_a)));
    dump_off off_b = dump_off_from_lisp (XCAR (XCDR (lreloc_b)));
    eassert (off_a <= off_b);  /* Catch sort errors.  */
    eassert (off_a < off_b);  /* Catch duplicate relocations.  */
  }
#endif

  if (XFIXNUM (XCAR (lreloc_a)) != RELOC_EMACS_COPY_FROM_DUMP
      || XFIXNUM (XCAR (lreloc_b)) != RELOC_EMACS_COPY_FROM_DUMP)
    return Qnil;

  struct emacs_reloc reloc_a = decode_emacs_reloc (NULL, lreloc_a);
  struct emacs_reloc reloc_b = decode_emacs_reloc (NULL, lreloc_b);

  eassert (reloc_a.type == RELOC_EMACS_COPY_FROM_DUMP);
  eassert (reloc_b.type == RELOC_EMACS_COPY_FROM_DUMP);

  if (reloc_a.emacs_offset + reloc_a.length != reloc_b.emacs_offset)
    return Qnil;

  if (reloc_a.u.dump_offset + reloc_a.length != reloc_b.u.dump_offset)
    return Qnil;

  dump_off new_length = reloc_a.length + reloc_b.length;
  reloc_a.length = new_length;
  if (reloc_a.length != new_length)
    return Qnil; /* Overflow */

  return list4 (make_fixnum (RELOC_EMACS_COPY_FROM_DUMP),
                dump_off_to_lisp (reloc_a.emacs_offset),
                dump_off_to_lisp (reloc_a.u.dump_offset),
                dump_off_to_lisp (reloc_a.length));
}

typedef void (*drain_reloc_handler) (struct dump_context *, Lisp_Object);
typedef Lisp_Object (*drain_reloc_merger) (Lisp_Object a, Lisp_Object b);

static void
drain_reloc_list (struct dump_context *ctx,
                  drain_reloc_handler handler,
                  drain_reloc_merger merger,
                  Lisp_Object *reloc_list,
                  struct dump_table_locator *out_locator)
{
  struct dump_flags old_flags = ctx->flags;
  Lisp_Object list_reversed, relocs;
  ctx->flags.pack_objects = true;
  list_reversed = Fnreverse (*reloc_list);
  relocs = CALLN (Fsort, list_reversed,
		  Qdump_emacs_portable__sort_predicate);
  *reloc_list = Qnil;
  dump_align_output (ctx, max (alignof (struct dump_reloc),
			       alignof (struct emacs_reloc)));
  struct dump_table_locator locator = {0};
  locator.offset = ctx->offset;
  for (; !NILP (relocs); locator.nr_entries += 1)
    {
      Lisp_Object reloc = dump_pop (&relocs);
      Lisp_Object merged;
      while (merger != NULL
	     && !NILP (relocs)
	     && (merged = merger (reloc, XCAR (relocs)), !NILP (merged)))
        {
          reloc = merged;
          relocs = XCDR (relocs);
        }
      handler (ctx, reloc);
    }
  *out_locator = locator;
  ctx->flags = old_flags;
}

static void
dump_do_fixup (struct dump_context *ctx,
               Lisp_Object fixup,
               Lisp_Object prev_fixup)
{
  enum dump_fixup_type type
    = (enum dump_fixup_type) XFIXNUM (dump_pop (&fixup));
  dump_off dump_fixup_offset = dump_off_from_lisp (dump_pop (&fixup));
#ifdef ENABLE_CHECKING
  if (!NILP (prev_fixup))
    {
      dump_off prev_dump_fixup_offset
	= dump_off_from_lisp (XCAR (XCDR (prev_fixup)));
      eassert (dump_fixup_offset - prev_dump_fixup_offset
	       >= sizeof (void *));
    }
#endif
  Lisp_Object arg = dump_pop (&fixup);
  eassert (NILP (fixup));
  dump_seek (ctx, dump_fixup_offset);
  intptr_t dump_value;
  bool do_write = true;
  switch (type)
    {
    case DUMP_FIXUP_LISP_OBJECT:
    case DUMP_FIXUP_LISP_OBJECT_RAW:
      /* Dump wants a pointer to a Lisp object.
         If DUMP_FIXUP_LISP_OBJECT_RAW, we should stick a C pointer in
         the dump; otherwise, a Lisp_Object.  */
      if (SUBRP (arg) && !NATIVE_COMP_FUNCTIONP (arg))
        {
          dump_value = emacs_offset (XSUBR (arg));
          if (type == DUMP_FIXUP_LISP_OBJECT)
            dump_reloc_dump_to_emacs_lv (ctx, ctx->offset, XTYPE (arg));
          else
            dump_reloc_dump_to_emacs_ptr_raw (ctx, ctx->offset);
        }
      else if (dump_builtin_symbol_p (arg))
        {
          eassert (dump_object_self_representing_p (arg));
          /* These symbols are part of Emacs, so point there.  If we
             want a Lisp_Object, we're set.  If we want a raw pointer,
             we need to emit a relocation.  */
          if (type == DUMP_FIXUP_LISP_OBJECT)
            {
              do_write = false;
              dump_write (ctx, &arg, sizeof (arg));
            }
          else
            {
              dump_value = emacs_offset (XSYMBOL (arg));
              dump_reloc_dump_to_emacs_ptr_raw (ctx, ctx->offset);
            }
        }
      else
        {
          eassert (dump_object_emacs_ptr (arg) == NULL);
          dump_value = dump_recall_object (ctx, arg);
          if (dump_value <= 0)
            error ("fixup object not dumped");
          if (type == DUMP_FIXUP_LISP_OBJECT)
            dump_reloc_dump_to_dump_lv (ctx, ctx->offset, XTYPE (arg));
          else
            dump_reloc_dump_to_dump_ptr_raw (ctx, ctx->offset);
        }
      break;
    case DUMP_FIXUP_PTR_DUMP_RAW:
      /* Dump wants a raw pointer to something that's not a lisp
         object.  It knows the exact location it wants, so just
         believe it.  */
      dump_value = dump_off_from_lisp (arg);
      dump_reloc_dump_to_dump_ptr_raw (ctx, ctx->offset);
      break;
    case DUMP_FIXUP_BIGNUM_DATA:
      {
        eassert (BIGNUMP (arg));
        arg = Fgethash (arg, ctx->bignum_data, Qnil);
        if (NILP (arg))
          error ("bignum not dumped");
        struct bignum_reload_info reload_info = { 0 };
        reload_info.data_location = dump_off_from_lisp (dump_pop (&arg));
        reload_info.nlimbs = dump_off_from_lisp (dump_pop (&arg));
        eassert (NILP (arg));
        dump_write (ctx, &reload_info, sizeof (reload_info));
        do_write = false;
        break;
      }
    default:
      emacs_abort ();
    }
  if (do_write)
    dump_write (ctx, &dump_value, sizeof (dump_value));
}

static void
dump_do_fixups (struct dump_context *ctx)
{
  dump_off saved_offset = ctx->offset;
  Lisp_Object fixups_reversed = Fnreverse (ctx->fixups);
  Lisp_Object fixups = CALLN (Fsort, fixups_reversed,
			      Qdump_emacs_portable__sort_predicate);
  Lisp_Object prev_fixup = Qnil;
  ctx->fixups = Qnil;
  while (!NILP (fixups))
    {
      Lisp_Object fixup = dump_pop (&fixups);
      dump_do_fixup (ctx, fixup, prev_fixup);
      prev_fixup = fixup;
    }
  dump_seek (ctx, saved_offset);
}

static void
dump_drain_normal_queue (struct dump_context *ctx)
{
  while (!dump_queue_empty_p (&ctx->dump_queue))
    dump_object (ctx, dump_queue_dequeue (&ctx->dump_queue, ctx->offset));
}

static void
dump_drain_deferred_hash_tables (struct dump_context *ctx)
{
  struct dump_flags old_flags = ctx->flags;

  /* Now we want to actually write the hash tables.  */
  ctx->flags.defer_hash_tables = false;

  Lisp_Object deferred_hash_tables = Fnreverse (ctx->deferred_hash_tables);
  ctx->deferred_hash_tables = Qnil;
  while (!NILP (deferred_hash_tables))
    dump_object (ctx, dump_pop (&deferred_hash_tables));
  ctx->flags = old_flags;
}

static void
dump_drain_deferred_symbols (struct dump_context *ctx)
{
  struct dump_flags old_flags = ctx->flags;

  /* Now we want to actually write the symbols.  */
  ctx->flags.defer_symbols = false;

  Lisp_Object deferred_symbols = Fnreverse (ctx->deferred_symbols);
  ctx->deferred_symbols = Qnil;
  while (!NILP (deferred_symbols))
    dump_object (ctx, dump_pop (&deferred_symbols));
  ctx->flags = old_flags;
}

DEFUN ("dump-emacs-portable",
       Fdump_emacs_portable, Sdump_emacs_portable,
       1, 2, 0,
       doc: /* Dump current state of Emacs into dump file FILENAME.
If TRACK-REFERRERS is non-nil, keep additional debugging information
that can help track down the provenance of unsupported object
types.  */)
     (Lisp_Object filename, Lisp_Object track_referrers)
{
  eassert (initialized);

#ifndef HAVE_ANDROID
  if (! noninteractive)
    error ("Dumping Emacs currently works only in batch mode.  "
           "If you'd like it to work interactively, please consider "
           "contributing a patch to Emacs.");
#endif

  if (!main_thread_p (current_thread))
    error ("This function can be called only in the main thread");

  if (!NILP (XCDR (Fall_threads ())))
    error ("No other Lisp threads can be running when this function is called");

#ifdef HAVE_NATIVE_COMP
  calln (intern_c_string ("load--fixup-all-elns"));
#endif

  /* Clear out any detritus in memory.  */
  do
    {
      number_finalizers_run = 0;
      garbage_collect ();
    }
  while (number_finalizers_run);

  specpdl_ref count = SPECPDL_INDEX ();

  /* Bind `command-line-processed' to nil before dumping,
     so that the dumped Emacs will process its command line
     and set up to work with X windows if appropriate.  */
  Lisp_Object symbol = Qcommand_line_processed;
  specbind (symbol, Qnil);

  CHECK_STRING (filename);
  filename = Fexpand_file_name (filename, Qnil);
  filename = ENCODE_FILE (filename);

  struct dump_context ctx_buf = {0};
  struct dump_context *ctx = &ctx_buf;
  ctx->fd = -1;

  ctx->objects_dumped = make_eq_hash_table ();
  dump_queue_init (&ctx->dump_queue);
  ctx->deferred_hash_tables = Qnil;
  ctx->deferred_symbols = Qnil;

  ctx->fixups = Qnil;
  ctx->staticpro_table = Fmake_hash_table (0, NULL);
  ctx->symbol_aux = Qnil;
  ctx->copied_queue = Qnil;
  ctx->cold_queue = Qnil;
  for (int i = 0; i < RELOC_NUM_PHASES; ++i)
    ctx->dump_relocs[i] = Qnil;
  ctx->object_starts = Qnil;
  ctx->emacs_relocs = Qnil;
  ctx->bignum_data = make_eq_hash_table ();

  /* Ordinarily, dump_object should remember where it saw objects and
     actually write the object contents to the dump file.  In special
     circumstances below, we temporarily change this default
     behavior.  */
  ctx->flags.dump_object_contents = true;
  ctx->flags.record_object_starts = true;

  /* We want to consolidate certain object types that we know are very likely
     to be modified.  */
  ctx->flags.defer_hash_tables = true;
  /* ctx->flags.defer_symbols = true; XXX  */

  /* These objects go into special sections.  */
  ctx->flags.defer_cold_objects = true;
  ctx->flags.defer_copied_objects = true;

  ctx->current_referrer = Qnil;
  if (!NILP (track_referrers))
    ctx->referrers = make_eq_hash_table ();

  ctx->dump_filename = filename;

  record_unwind_protect_ptr (dump_unwind_cleanup, ctx);
  block_input ();

#ifdef REL_ALLOC
  r_alloc_inhibit_buffer_relocation (1);
  ctx->blocked_ralloc = true;
#endif

  ctx->old_purify_flag = Vpurify_flag;
  Vpurify_flag = Qnil;

  /* Make sure various weird things are less likely to happen.  */
  ctx->old_post_gc_hook = Vpost_gc_hook;
  Vpost_gc_hook = Qnil;

  /* Reset process-environment -- this is for when they re-dump a
     pdump-restored emacs, since set_initial_environment wants always
     to cons it from scratch.  */
  ctx->old_process_environment = Vprocess_environment;
  Vprocess_environment = Qnil;

  {
    USE_SAFE_ALLOCA;

    char *filename_1;
    SAFE_ALLOCA_STRING (filename_1, filename);
#ifdef MSDOS
    /* Rewrite references to .pdmp to refer to .dmp files on DOS.  */
    size_t len = strlen (filename_1);
    if (len >= 5
	&& !strcmp (filename_1 + len - 5, ".pdmp"))
      {
	strcpy (filename_1 + len - 5, ".dmp");
	filename = DECODE_FILE (build_unibyte_string (filename_1));
      }
#endif /* MSDOS */
    ctx->fd = emacs_open (filename_1, O_RDWR | O_TRUNC | O_CREAT, 0666);
    SAFE_FREE ();
  }
  if (ctx->fd < 0)
    report_file_error ("Opening dump output", filename);
  static_assert (sizeof (ctx->header.magic) == sizeof (dump_magic));
  memcpy (&ctx->header.magic, dump_magic, sizeof (dump_magic));
  ctx->header.magic[0] = '!'; /* Note that dump is incomplete.  */

  static_assert (sizeof (fingerprint) == sizeof (ctx->header.fingerprint));
  for (int i = 0; i < sizeof fingerprint; i++)
    ctx->header.fingerprint[i] = fingerprint[i];

  const dump_off header_start = ctx->offset;
  dump_fingerprint (stderr, "Dumping fingerprint", ctx->header.fingerprint);
  dump_write (ctx, &ctx->header, sizeof (ctx->header));
  const dump_off header_end = ctx->offset;

  const dump_off hot_start = ctx->offset;
  /* Start the dump process by processing the static roots and
     queuing up the objects to which they refer.   */
  dump_roots (ctx);

  dump_charset_table (ctx);
  dump_finalizer_list_head_ptr (ctx, &finalizers.prev);
  dump_finalizer_list_head_ptr (ctx, &finalizers.next);
  dump_finalizer_list_head_ptr (ctx, &doomed_finalizers.prev);
  dump_finalizer_list_head_ptr (ctx, &doomed_finalizers.next);
  dump_drain_user_remembered_data_hot (ctx);

  /* We've already remembered all the objects to which GC roots point,
     but we have to manually save the list of GC roots itself.  */
  dump_metadata_for_pdumper (ctx);
  for (int i = 0; i < staticidx; ++i)
    dump_emacs_reloc_to_emacs_ptr_raw (ctx, &staticvec[i], staticvec[i]);
  dump_emacs_reloc_immediate_int (ctx, &staticidx, staticidx);

  /* Dump while we keep finding objects to dump.  We add new
     objects to the queue by side effect during dumping.
     We accumulate some types of objects in special lists to get more
     locality for these object types at runtime.  */
  do
    {
      dump_drain_deferred_hash_tables (ctx);
      dump_drain_deferred_symbols (ctx);
      dump_drain_normal_queue (ctx);
    }
  while (!(dump_queue_empty_p (&ctx->dump_queue)
	   && NILP (ctx->deferred_hash_tables)
	   && NILP (ctx->deferred_symbols)));

  ctx->header.hash_list = ctx->offset;
  dump_hash_table_list (ctx);

  /* dump_hash_table_list just adds a new vector to the dump but all
     its content should already have been in the dump, so it doesn't
     add anything to any queue.  */
  eassert (dump_queue_empty_p (&ctx->dump_queue)
	   && NILP (ctx->deferred_hash_tables)
	   && NILP (ctx->deferred_symbols));

  dump_sort_copied_objects (ctx);

  /* While we copy built-in symbols into the Emacs image, these
     built-in structures refer to non-Lisp heap objects that must live
     in the dump; we stick these auxiliary data structures at the end
     of the hot section and use a special hash table to remember them.
     The actual symbol dump will pick them up below.  */
  ctx->symbol_aux = make_eq_hash_table ();
  dump_hot_parts_of_discardable_objects (ctx);

  /* Emacs, after initial dump loading, can forget about the portion
     of the dump that runs from here to the start of the cold section.
     This section consists of objects that need to be memcpy()ed into
     the Emacs data section instead of just used directly.

     We don't need to align hot_end: the loader knows to actually
     start discarding only at the next page boundary if the loader
     implements discarding using page manipulation.  */
  const dump_off hot_end = ctx->offset;
  ctx->header.discardable_start = hot_end;

  dump_drain_copied_objects (ctx);
  eassert (dump_queue_empty_p (&ctx->dump_queue));

  dump_off discardable_end = ctx->offset;
  dump_align_output (ctx, dump_get_max_page_size ());
  ctx->header.cold_start = ctx->offset;

  /* Start the cold section.  This section contains bytes that should
     never change and so can be direct-mapped from the dump without
     special processing.  */
  dump_drain_cold_data (ctx);
   /* dump_drain_user_remembered_data_cold needs to be after
      dump_drain_cold_data in case dump_drain_cold_data dumps a lisp
      object to which C code points.
      dump_drain_user_remembered_data_cold assumes that all lisp
      objects have been dumped.  */
  dump_drain_user_remembered_data_cold (ctx);

  /* After this point, the dump file contains no data that can be part
     of the Lisp heap.  */
  ctx->end_heap = ctx->offset;

  /* Make remembered modifications to the dump file itself.  */
  dump_do_fixups (ctx);

  drain_reloc_merger emacs_reloc_merger =
#ifdef ENABLE_CHECKING
    dump_check_overlap_dump_reloc
#else
    NULL
#endif
    ;

  /* Emit instructions for Emacs to execute when loading the dump.
     Note that this relocation information ends up in the cold section
     of the dump.  */
  for (int i = 0; i < RELOC_NUM_PHASES; ++i)
    drain_reloc_list (ctx, dump_emit_dump_reloc, emacs_reloc_merger,
		      &ctx->dump_relocs[i], &ctx->header.dump_relocs[i]);
  dump_off number_hot_relocations = ctx->number_hot_relocations;
  ctx->number_hot_relocations = 0;
  dump_off number_discardable_relocations = ctx->number_discardable_relocations;
  ctx->number_discardable_relocations = 0;
  drain_reloc_list (ctx, dump_emit_dump_reloc, emacs_reloc_merger,
		    &ctx->object_starts, &ctx->header.object_starts);
  drain_reloc_list (ctx, dump_emit_emacs_reloc, dump_merge_emacs_relocs,
		    &ctx->emacs_relocs, &ctx->header.emacs_relocs);

  const dump_off cold_end = ctx->offset;

  eassert (dump_queue_empty_p (&ctx->dump_queue));
  eassert (NILP (ctx->copied_queue));
  eassert (NILP (ctx->cold_queue));
  eassert (NILP (ctx->deferred_symbols));
  eassert (NILP (ctx->deferred_hash_tables));
  eassert (NILP (ctx->fixups));
  for (int i = 0; i < RELOC_NUM_PHASES; ++i)
    eassert (NILP (ctx->dump_relocs[i]));
  eassert (NILP (ctx->emacs_relocs));

  /* Dump is complete.  Go back to the header and write the magic
     indicating that the dump is complete and can be loaded.  */
  ctx->header.magic[0] = dump_magic[0];
  dump_seek (ctx, 0);
  dump_write (ctx, &ctx->header, sizeof (ctx->header));
  if (emacs_write (ctx->fd, ctx->buf, ctx->max_offset) < ctx->max_offset)
    report_file_error ("Could not write to dump file", ctx->dump_filename);
  xfree (ctx->buf);
  ctx->buf = NULL;
  ctx->buf_size = 0;
  ctx->max_offset = 0;

  dump_off
    header_bytes = header_end - header_start,
    hot_bytes = hot_end - hot_start,
    discardable_bytes = discardable_end - ctx->header.discardable_start,
    cold_bytes = cold_end - ctx->header.cold_start;
  fprintf (stderr,
	   ("Dump complete\n"
	    "Byte counts: header=%"PRIdDUMP_OFF" hot=%"PRIdDUMP_OFF
	    " discardable=%"PRIdDUMP_OFF" cold=%"PRIdDUMP_OFF"\n"
	    "Reloc counts: hot=%"PRIdDUMP_OFF" discardable=%"PRIdDUMP_OFF"\n"),
	   header_bytes, hot_bytes, discardable_bytes, cold_bytes,
           number_hot_relocations,
           number_discardable_relocations);

  unblock_input ();
  return unbind_to (count, Qnil);
}

DEFUN ("dump-emacs-portable--sort-predicate",
       Fdump_emacs_portable__sort_predicate,
       Sdump_emacs_portable__sort_predicate,
       2, 2, 0,
       doc: /* Internal relocation sorting function.  */)
     (Lisp_Object a, Lisp_Object b)
{
  dump_off a_offset = dump_off_from_lisp (XCAR (XCDR (a)));
  dump_off b_offset = dump_off_from_lisp (XCAR (XCDR (b)));
  return a_offset < b_offset ? Qt : Qnil;
}

DEFUN ("dump-emacs-portable--sort-predicate-copied",
       Fdump_emacs_portable__sort_predicate_copied,
       Sdump_emacs_portable__sort_predicate_copied,
       2, 2, 0,
       doc: /* Internal relocation sorting function.  */)
     (Lisp_Object a, Lisp_Object b)
{
  eassert (dump_object_emacs_ptr (a));
  eassert (dump_object_emacs_ptr (b));
  return dump_object_emacs_ptr (a) < dump_object_emacs_ptr (b) ? Qt : Qnil;
}

void
pdumper_do_now_and_after_load_impl (pdumper_hook hook)
{
  if (nr_dump_hooks == ARRAYELTS (dump_hooks))
    fatal ("out of dump hooks: make dump_hooks[] bigger");
  dump_hooks[nr_dump_hooks++] = hook;
  hook ();
}

void
pdumper_do_now_and_after_late_load_impl (pdumper_hook hook)
{
  if (nr_dump_late_hooks == ARRAYELTS (dump_late_hooks))
    fatal ("out of dump hooks: make dump_late_hooks[] bigger");
  dump_late_hooks[nr_dump_late_hooks++] = hook;
  hook ();
}

static void
pdumper_remember_user_data_1 (void *mem, int nbytes)
{
  if (nr_remembered_data == ARRAYELTS (remembered_data))
    fatal ("out of remembered data slots: make remembered_data[] bigger");
  remembered_data[nr_remembered_data].mem = mem;
  remembered_data[nr_remembered_data].sz = nbytes;
  nr_remembered_data += 1;
}

void
pdumper_remember_scalar_impl (void *mem, ptrdiff_t nbytes)
{
  eassert (0 <= nbytes && nbytes <= INT_MAX);
  if (nbytes > 0)
    pdumper_remember_user_data_1 (mem, (int) nbytes);
}

void
pdumper_remember_lv_ptr_raw_impl (void *ptr, enum Lisp_Type type)
{
  pdumper_remember_user_data_1 (ptr, -type);
}


#ifdef HAVE_NATIVE_COMP
/* This records the directory where the Emacs executable lives, to be
   used for locating the native-lisp directory from which we need to
   load the preloaded *.eln files.  See pdumper_set_emacs_execdir
   below.  */
static char *emacs_execdir;
static ptrdiff_t execdir_size;
static ptrdiff_t execdir_len;
#endif

/* Dump runtime */
enum dump_memory_protection
{
  DUMP_MEMORY_ACCESS_NONE = 1,
  DUMP_MEMORY_ACCESS_READ = 2,
  DUMP_MEMORY_ACCESS_READWRITE = 3,
};

#if VM_SUPPORTED == VM_MS_WINDOWS
static void *
dump_anonymous_allocate_w32 (void *base,
                             size_t size,
                             enum dump_memory_protection protection)
{
  void *ret;
  DWORD mem_type;
  DWORD mem_prot;

  switch (protection)
    {
    case DUMP_MEMORY_ACCESS_NONE:
      mem_type = MEM_RESERVE;
      mem_prot = PAGE_NOACCESS;
      break;
    case DUMP_MEMORY_ACCESS_READ:
      mem_type = MEM_COMMIT;
      mem_prot = PAGE_READONLY;
      break;
    case DUMP_MEMORY_ACCESS_READWRITE:
      mem_type = MEM_COMMIT;
      mem_prot = PAGE_READWRITE;
      break;
    default:
      emacs_abort ();
    }

  ret = VirtualAlloc (base, size, mem_type, mem_prot);
  if (ret == NULL)
    errno = (base && GetLastError () == ERROR_INVALID_ADDRESS)
      ? EBUSY
      : EPERM;
  return ret;
}
#endif

#if VM_SUPPORTED == VM_POSIX

/* Old versions of macOS only define MAP_ANON, not MAP_ANONYMOUS.
   FIXME: This probably belongs elsewhere (gnulib/autoconf?)  */
# ifndef MAP_ANONYMOUS
#  define MAP_ANONYMOUS MAP_ANON
# endif

static void *
dump_anonymous_allocate_posix (void *base,
                               size_t size,
                               enum dump_memory_protection protection)
{
  void *ret;
  int mem_prot;

  switch (protection)
    {
    case DUMP_MEMORY_ACCESS_NONE:
      mem_prot = PROT_NONE;
      break;
    case DUMP_MEMORY_ACCESS_READ:
      mem_prot = PROT_READ;
      break;
    case DUMP_MEMORY_ACCESS_READWRITE:
      mem_prot = PROT_READ | PROT_WRITE;
      break;
    default:
      emacs_abort ();
    }

  int mem_flags = MAP_PRIVATE | MAP_ANONYMOUS;
  if (mem_prot != PROT_NONE)
    mem_flags |= MAP_POPULATE;
  if (base)
    mem_flags |= MAP_FIXED;

  bool retry;
  do
    {
      retry = false;
      ret = mmap (base, size, mem_prot, mem_flags, -1, 0);
      if (ret == MAP_FAILED
	  && errno == EINVAL
	  && (mem_flags & MAP_POPULATE))
        {
          /* This system didn't understand MAP_POPULATE, so try
             again without it.  */
          mem_flags &= ~MAP_POPULATE;
          retry = true;
        }
    }
  while (retry);

  if (ret == MAP_FAILED)
    ret = NULL;
  return ret;
}
#endif

/* Undo the effect of `dump_reserve_address_space'.  */

static void
dump_anonymous_release (void *addr, size_t size)
{
  eassert (size >= 0);
#if VM_SUPPORTED == VM_MS_WINDOWS
  (void) size;
  if (!VirtualFree (addr, 0, MEM_RELEASE))
    emacs_abort ();
#elif VM_SUPPORTED == VM_POSIX
  if (munmap (addr, size) < 0)
    emacs_abort ();
#else
  (void) addr;
  (void) size;
  emacs_abort ();
#endif
}

/* Perform anonymous memory allocation.  */
static void *
dump_anonymous_allocate (void *base,
                         const size_t size,
                         enum dump_memory_protection protection)
{
  void *val;

#if VM_SUPPORTED == VM_POSIX
  val = dump_anonymous_allocate_posix (base, size, protection);
#elif VM_SUPPORTED == VM_MS_WINDOWS
  val = dump_anonymous_allocate_w32 (base, size, protection);
#else
  errno = ENOSYS;
  val = NULL;
#endif

  return val;
}

#if VM_SUPPORTED == VM_MS_WINDOWS
static void *
dump_map_file_w32 (void *base, int fd, off_t offset, size_t size,
		   enum dump_memory_protection protection)
{
  void *ret = NULL;
  HANDLE section = NULL;
  HANDLE file;

  uint64_t full_offset = offset;
  uint32_t offset_high = (uint32_t) (full_offset >> 32);
  uint32_t offset_low = (uint32_t) (full_offset & 0xffffffff);

  int error;
  DWORD protect;
  DWORD map_access;

  file = (HANDLE) _get_osfhandle (fd);
  if (file == INVALID_HANDLE_VALUE)
    goto out;

  switch (protection)
    {
    case DUMP_MEMORY_ACCESS_READWRITE:
      protect = PAGE_WRITECOPY;	/* for Windows 9X */
      break;
    default:
    case DUMP_MEMORY_ACCESS_NONE:
    case DUMP_MEMORY_ACCESS_READ:
      protect = PAGE_READONLY;
      break;
    }

  section = CreateFileMapping (file,
			       /*lpAttributes=*/NULL,
			       protect,
			       /*dwMaximumSizeHigh=*/0,
			       /*dwMaximumSizeLow=*/0,
			       /*lpName=*/NULL);
  if (!section)
    {
      errno = EINVAL;
      goto out;
    }

  switch (protection)
    {
    case DUMP_MEMORY_ACCESS_NONE:
    case DUMP_MEMORY_ACCESS_READ:
      map_access = FILE_MAP_READ;
      break;
    case DUMP_MEMORY_ACCESS_READWRITE:
      map_access = FILE_MAP_COPY;
      break;
    default:
      emacs_abort ();
    }

  ret = MapViewOfFileEx (section,
                         map_access,
                         offset_high,
                         offset_low,
                         size,
                         base);

  error = GetLastError ();
  if (ret == NULL)
    errno = (error == ERROR_INVALID_ADDRESS ? EBUSY : EPERM);
 out:
  if (section && !CloseHandle (section))
    emacs_abort ();
  return ret;
}
#endif

#if VM_SUPPORTED == VM_POSIX
static void *
dump_map_file_posix (void *base, int fd, off_t offset, size_t size,
		     enum dump_memory_protection protection)
{
  void *ret;
  int mem_prot;
  int mem_flags;

  switch (protection)
    {
    case DUMP_MEMORY_ACCESS_NONE:
      mem_prot = PROT_NONE;
      mem_flags = MAP_SHARED;
      break;
    case DUMP_MEMORY_ACCESS_READ:
      mem_prot = PROT_READ;
      mem_flags = MAP_SHARED;
      break;
    case DUMP_MEMORY_ACCESS_READWRITE:
      mem_prot = PROT_READ | PROT_WRITE;
      mem_flags = MAP_PRIVATE;
      break;
    default:
      emacs_abort ();
    }

  if (base)
    mem_flags |= MAP_FIXED;

  ret = mmap (base, size, mem_prot, mem_flags, fd, offset);
  if (ret == MAP_FAILED)
    ret = NULL;
  return ret;
}
#endif

/* Map a file into memory.  */
static void *
dump_map_file (void *base, int fd, off_t offset, size_t size,
	       enum dump_memory_protection protection)
{
#if VM_SUPPORTED == VM_POSIX
  return dump_map_file_posix (base, fd, offset, size, protection);
#elif VM_SUPPORTED == VM_MS_WINDOWS
  return dump_map_file_w32 (base, fd, offset, size, protection);
#else
  errno = ENOSYS;
  return NULL;
#endif
}

/* Remove a virtual memory mapping.

   On failure, abort Emacs.  For maximum platform compatibility, ADDR
   and SIZE must match the mapping exactly.  */
static void
dump_unmap_file (void *addr, size_t size)
{
  eassert (size >= 0);
#if !VM_SUPPORTED
  (void) addr;
  (void) size;
  emacs_abort ();
#elif defined (WINDOWSNT)
  (void) size;
  if (!UnmapViewOfFile (addr))
    emacs_abort ();
#else
  if (munmap (addr, size) < 0)
    emacs_abort ();
#endif
}

struct dump_memory_map_spec
{
  int fd;  /* File to map; anon zero if negative.  */
  size_t size;  /* Number of bytes to map.  */
  off_t offset;  /* Offset within fd.  */
  enum dump_memory_protection protection;
};

struct dump_memory_map
{
  struct dump_memory_map_spec spec;
  void *mapping;  /* Actual mapped memory.  */
  void (*release) (struct dump_memory_map *);
  void *private;
};

/* Mark the pages as unneeded, potentially zeroing them, without
   releasing the address space reservation.  */
static void
dump_discard_mem (void *mem, size_t size)
{
#if VM_SUPPORTED == VM_MS_WINDOWS
  /* Discard COWed pages.  */
  (void) VirtualFree (mem, size, MEM_DECOMMIT);
  /* Release the commit charge for the mapping.  */
  DWORD old_prot;
  (void) VirtualProtect (mem, size, PAGE_NOACCESS, &old_prot);
#elif VM_SUPPORTED == VM_POSIX
# ifdef HAVE_POSIX_MADVISE
  /* Discard COWed pages.  */
  (void) posix_madvise (mem, size, POSIX_MADV_DONTNEED);
# elif defined HAVE_MADVISE
  (void) madvise (mem, size, MADV_DONTNEED);
#endif
  /* Release the commit charge for the mapping.  */
  (void) mprotect (mem, size, PROT_NONE);
#endif
}

static void
dump_mmap_discard_contents (struct dump_memory_map *map)
{
  if (map->mapping)
    dump_discard_mem (map->mapping, map->spec.size);
}

static void
dump_mmap_reset (struct dump_memory_map *map)
{
  map->mapping = NULL;
  map->release = NULL;
  map->private = NULL;
}

static void
dump_mmap_release (struct dump_memory_map *map)
{
  if (map->release)
    map->release (map);
  dump_mmap_reset (map);
}

/* Allows heap-allocated dump_mmap to "free" maps individually.  */
struct dump_memory_map_heap_control_block
{
  int refcount;
  void *mem;
};

static void
dump_mm_heap_cb_release (struct dump_memory_map_heap_control_block *cb)
{
  if (cb)
    {
      eassert (cb->refcount > 0);
      if (--cb->refcount == 0)
	{
	  free (cb->mem);
	  free (cb);
	}
    }
}

static void
dump_mmap_release_heap (struct dump_memory_map *map)
{
  dump_mm_heap_cb_release (map->private);
}

/* Implement dump_mmap using malloc and read.  */
static bool
dump_mmap_contiguous_heap (struct dump_memory_map *maps, int nr_maps,
			   size_t total_size)
{
  bool ret = false;

  /* FIXME: This storage sometimes is never freed.
     Beware: the simple patch 2019-03-11T15:20:54Z!eggert@cs.ucla.edu
     is worse, as it sometimes frees this storage twice.  */
  struct dump_memory_map_heap_control_block *cb = calloc (1, sizeof (*cb));
  if (!cb)
    goto out;
  __lsan_ignore_object (cb);

  cb->refcount = 1;
  cb->mem = malloc (total_size);
  if (!cb->mem)
    goto out;
  char *mem = cb->mem;
  for (int i = 0; i < nr_maps; ++i)
    {
      struct dump_memory_map *map = &maps[i];
      const struct dump_memory_map_spec spec = map->spec;
      if (!spec.size)
        continue;
      map->mapping = mem;
      mem += spec.size;
      map->release = dump_mmap_release_heap;
      map->private = cb;
      cb->refcount += 1;
      if (spec.fd < 0)
        memset (map->mapping, 0, spec.size);
      else
        {
          if (lseek (spec.fd, spec.offset, SEEK_SET) < 0)
            goto out;
          ssize_t nb = dump_read_all (spec.fd,
                                      map->mapping,
                                      spec.size);
          if (nb >= 0 && nb != spec.size)
            errno = EIO;
          if (nb != spec.size)
            goto out;
        }
    }

  ret = true;
 out:
  dump_mm_heap_cb_release (cb);
  if (!ret)
    for (int i = 0; i < nr_maps; ++i)
      dump_mmap_release (&maps[i]);
  return ret;
}

static void
dump_mmap_release_vm (struct dump_memory_map *map)
{
  if (map->spec.fd < 0)
    dump_anonymous_release (map->mapping, map->spec.size);
  else
    dump_unmap_file (map->mapping, map->spec.size);
}

static bool
needs_mmap_retry_p (void)
{
#if defined CYGWIN || VM_SUPPORTED == VM_MS_WINDOWS \
  || defined _AIX
  return true;
#else /* !CYGWIN && VM_SUPPORTED != VM_MS_WINDOWS && !_AIX */
  return false;
#endif /* !CYGWIN && VM_SUPPORTED != VM_MS_WINDOWS && !_AIX */
}

static bool
dump_mmap_contiguous_vm (struct dump_memory_map *maps, int nr_maps,
			 size_t total_size)
{
  int save_errno;
  bool ret = false;
  void *resv = NULL;
  bool retry = false;
  bool need_retry = needs_mmap_retry_p ();

  do
    {
      if (retry)
        {
          eassert (need_retry);
          retry = false;
          for (int i = 0; i < nr_maps; ++i)
            dump_mmap_release (&maps[i]);
        }

      eassert (resv == NULL);
      resv = dump_anonymous_allocate (NULL, total_size,
                                      DUMP_MEMORY_ACCESS_NONE);
      if (!resv)
	goto out;

      char *mem = resv;

      if (need_retry)
        {
          /* Windows lacks atomic mapping replace; need to release the
             reservation so we can allocate within it.  Will retry the
             loop if someone squats on our address space before we can
             finish allocation.  On POSIX systems, we leave the
             reservation around for atomicity.  */
          dump_anonymous_release (resv, total_size);
          resv = NULL;
        }

      for (int i = 0; i < nr_maps; ++i)
        {
          struct dump_memory_map *map = &maps[i];
          const struct dump_memory_map_spec spec = map->spec;
          if (!spec.size)
            continue;

          if (spec.fd < 0)
	    map->mapping = dump_anonymous_allocate (mem, spec.size,
						    spec.protection);
          else
	    map->mapping = dump_map_file (mem, spec.fd, spec.offset,
					  spec.size, spec.protection);
          mem += spec.size;
	  if (need_retry && map->mapping == NULL
	      && (errno == EBUSY
#ifdef CYGWIN
		  || errno == EINVAL
#endif
		  ))
            {
              retry = true;
              continue;
            }
          if (map->mapping == NULL)
            goto out;
          map->release = dump_mmap_release_vm;
        }
    }
  while (retry);

  ret = true;
  resv = NULL;
 out:
  save_errno = errno;
  if (resv)
    dump_anonymous_release (resv, total_size);
  if (!ret)
    {
      for (int i = 0; i < nr_maps; ++i)
	{
	  if (need_retry)
	    dump_mmap_reset (&maps[i]);
	  else
	    dump_mmap_release (&maps[i]);
	}
    }
  errno = save_errno;
  return ret;
}

/* Map a range of addresses into a chunk of contiguous memory.

   Each dump_memory_map structure describes how to fill the
   corresponding range of memory. On input, all members except MAPPING
   are valid.  On output, MAPPING contains the location of the given
   chunk of memory.  The MAPPING for MAPS[N] is MAPS[N-1].mapping +
   MAPS[N-1].size.

   Each mapping SIZE must be a multiple of the system page size except
   for the last mapping.

   Return true on success or false on failure with errno set.  */
static bool
dump_mmap_contiguous (struct dump_memory_map *maps, int nr_maps)
{
  if (!nr_maps)
    return true;

  size_t total_size = 0;
  int worst_case_page_size = dump_get_max_page_size ();

  for (int i = 0; i < nr_maps; ++i)
    {
      eassert (maps[i].mapping == NULL);
      eassert (maps[i].release == NULL);
      eassert (maps[i].private == NULL);
      if (i != nr_maps - 1)
        eassert (maps[i].spec.size % worst_case_page_size == 0);
      total_size += maps[i].spec.size;
    }

  if (VM_SUPPORTED)
    return dump_mmap_contiguous_vm (maps, nr_maps, total_size);
  else
    return dump_mmap_contiguous_heap (maps, nr_maps, total_size);
}

typedef uint_fast32_t dump_bitset_word;
#define DUMP_BITSET_WORD_WIDTH UINT_FAST32_WIDTH

struct dump_bitset
{
  dump_bitset_word *restrict bits;
  ptrdiff_t number_words;
};

static bool
dump_bitsets_init (struct dump_bitset bitset[2], size_t number_bits)
{
  int xword_size = sizeof (dump_bitset_word);
  ptrdiff_t words_needed = divide_round_up (number_bits,
					    DUMP_BITSET_WORD_WIDTH);
  dump_bitset_word *bits = calloc (words_needed, 2 * xword_size);
  if (!bits)
    return false;
  bitset[0].bits = bits;
  bitset[0].number_words = bitset[1].number_words = words_needed;
  bitset[1].bits = memset (bits + words_needed, UCHAR_MAX,
			   words_needed * xword_size);
  return true;
}

static dump_bitset_word *
dump_bitset__bit_slot (const struct dump_bitset *bitset,
                       size_t bit_number)
{
  ptrdiff_t word_number = bit_number / DUMP_BITSET_WORD_WIDTH;
  eassert (word_number < bitset->number_words);
  return &bitset->bits[word_number];
}

static bool
dump_bitset_bit_set_p (const struct dump_bitset *bitset,
                       size_t bit_number)
{
  dump_bitset_word bit = 1;
  bit <<= bit_number % DUMP_BITSET_WORD_WIDTH;
  return (*dump_bitset__bit_slot (bitset, bit_number) & bit) != 0;
}

static void
dump_bitset__set_bit_value (struct dump_bitset *bitset,
                            size_t bit_number,
                            bool bit_is_set)
{
  dump_bitset_word *slot = dump_bitset__bit_slot (bitset, bit_number);
  dump_bitset_word bit = 1;
  bit <<= bit_number % DUMP_BITSET_WORD_WIDTH;
  if (bit_is_set)
    *slot = *slot | bit;
  else
    *slot = *slot & ~bit;
}

static void
dump_bitset_set_bit (struct dump_bitset *bitset, size_t bit_number)
{
  dump_bitset__set_bit_value (bitset, bit_number, true);
}

static void
dump_bitset_clear (struct dump_bitset *bitset)
{
  /* Skip the memset if bitset->number_words == 0, because then bitset->bits
     might be NULL and the memset would have undefined behavior.  */
  if (bitset->number_words)
    memset (bitset->bits, 0, bitset->number_words * sizeof bitset->bits[0]);
}

struct pdumper_loaded_dump_private
{
  /* Copy of the header we read from the dump.  */
  struct dump_header header;
  /* Mark bits for objects in the dump; used during GC.  */
  struct dump_bitset mark_bits, last_mark_bits;
  /* Time taken to load the dump.  */
  double load_time;
  /* Dump file name.  */
  char *dump_filename;
};

struct pdumper_loaded_dump dump_public;
static struct pdumper_loaded_dump_private dump_private;

/* Return a pointer to offset OFFSET within the dump, which begins at
   DUMP_BASE. DUMP_BASE must be equal to the current dump load
   location; it's passed as a parameter for efficiency.

   The returned pointer points to the primary memory image of the
   currently-loaded dump file.  The entire dump file is accessible
   using this function.  */
static void *
dump_ptr (uintptr_t dump_base, dump_off offset)
{
  eassert (dump_base == dump_public.start);
  eassert (0 <= offset);
  eassert (dump_public.start + offset < dump_public.end);
  return (char *)dump_base + offset;
}

/* Read a pointer-sized word of memory at OFFSET within the dump,
   which begins at DUMP_BASE. DUMP_BASE must be equal to the current
   dump load location; it's passed as a parameter for efficiency.  */
static uintptr_t
dump_read_word_from_dump (uintptr_t dump_base, dump_off offset)
{
  uintptr_t value;
  /* The compiler optimizes this memcpy into a read.  */
  memcpy (&value, dump_ptr (dump_base, offset), sizeof (value));
  return value;
}

/* Write a word to the dump. DUMP_BASE and OFFSET are as for
   dump_read_word_from_dump; VALUE is the word to write at the given
   offset.  */
static void
dump_write_word_to_dump (uintptr_t dump_base,
                         dump_off offset,
                         uintptr_t value)
{
  /* The compiler optimizes this memcpy into a write.  */
  memcpy (dump_ptr (dump_base, offset), &value, sizeof (value));
}

/* Write a Lisp_Object to the dump. DUMP_BASE and OFFSET are as for
   dump_read_word_from_dump; VALUE is the Lisp_Object to write at the
   given offset.  */
static void
dump_write_lv_to_dump (uintptr_t dump_base,
                       dump_off offset,
                       Lisp_Object value)
{
  /* The compiler optimizes this memcpy into a write.  */
  memcpy (dump_ptr (dump_base, offset), &value, sizeof (value));
}

/* Search for a relocation given a relocation target.

   DUMP is the dump metadata structure.  TABLE is the relocation table
   to search.  KEY is the dump offset to find.  Return the relocation
   RELOC such that RELOC.offset is the smallest RELOC.offset that
   satisfies the constraint KEY <= RELOC.offset --- that is, return
   the first relocation at KEY or after KEY.  Return NULL if no such
   relocation exists.  */
static const struct dump_reloc *
dump_find_relocation (const struct dump_table_locator *const table,
                      const dump_off key)
{
  const struct dump_reloc *const relocs = dump_ptr (dump_public.start,
						    table->offset);
  const struct dump_reloc *found = NULL;
  ptrdiff_t idx_left = 0;
  ptrdiff_t idx_right = table->nr_entries;

  eassert (key >= 0);

  while (idx_left < idx_right)
    {
      const ptrdiff_t idx_mid = idx_left + (idx_right - idx_left) / 2;
      const struct dump_reloc *mid = &relocs[idx_mid];
      if (key > dump_reloc_get_offset (*mid))
        idx_left = idx_mid + 1;
      else
        {
          found = mid;
          idx_right = idx_mid;
	  if (idx_right <= idx_left
	      || key > dump_reloc_get_offset (relocs[idx_right - 1]))
            break;
        }
   }

  return found;
}

static bool
dump_loaded_p (void)
{
  return dump_public.start != 0;
}

bool
pdumper_cold_object_p_impl (const void *obj)
{
  eassert (pdumper_object_p (obj));
  eassert (pdumper_object_p_precise (obj));
  dump_off offset = ptrdiff_t_to_dump_off ((uintptr_t) obj - dump_public.start);
  return offset >= dump_private.header.cold_start;
}

int
pdumper_find_object_type_impl (const void *obj)
{
  eassert (pdumper_object_p (obj));
  dump_off offset = ptrdiff_t_to_dump_off ((uintptr_t) obj - dump_public.start);
  if (offset % DUMP_ALIGNMENT != 0)
    return PDUMPER_NO_OBJECT;
  ptrdiff_t bitno = offset / DUMP_ALIGNMENT;
  if (offset < dump_private.header.discardable_start
      && !dump_bitset_bit_set_p (&dump_private.last_mark_bits, bitno))
    return PDUMPER_NO_OBJECT;
  const struct dump_reloc *reloc =
    dump_find_relocation (&dump_private.header.object_starts, offset);
  return (reloc != NULL && dump_reloc_get_offset (*reloc) == offset)
    ? reloc->type
    : PDUMPER_NO_OBJECT;
}

bool
pdumper_marked_p_impl (const void *obj)
{
  eassert (pdumper_object_p (obj));
  ptrdiff_t offset = (uintptr_t) obj - dump_public.start;
  eassert (offset % DUMP_ALIGNMENT == 0);
  eassert (offset < dump_private.header.cold_start);
  eassert (offset < dump_private.header.discardable_start);
  ptrdiff_t bitno = offset / DUMP_ALIGNMENT;
  return dump_bitset_bit_set_p (&dump_private.mark_bits, bitno);
}

void
pdumper_set_marked_impl (const void *obj)
{
  eassert (pdumper_object_p (obj));
  ptrdiff_t offset = (uintptr_t) obj - dump_public.start;
  eassert (offset % DUMP_ALIGNMENT == 0);
  eassert (offset < dump_private.header.cold_start);
  eassert (offset < dump_private.header.discardable_start);
  ptrdiff_t bitno = offset / DUMP_ALIGNMENT;
  eassert (dump_bitset_bit_set_p (&dump_private.last_mark_bits, bitno));
  dump_bitset_set_bit (&dump_private.mark_bits, bitno);
}

void
pdumper_clear_marks_impl (void)
{
  dump_bitset_word *swap = dump_private.last_mark_bits.bits;
  dump_private.last_mark_bits.bits = dump_private.mark_bits.bits;
  dump_private.mark_bits.bits = swap;
  dump_bitset_clear (&dump_private.mark_bits);
}

static ssize_t
dump_read_all (int fd, void *buf, size_t bytes_to_read)
{
  /* We don't want to use emacs_read, since that relies on the lisp
     world, and we're not in the lisp world yet.  */
  size_t bytes_read = 0;
  while (bytes_read < bytes_to_read)
    {
      int chunk_to_read = min (bytes_to_read - bytes_read, MAX_RW_COUNT);
      ssize_t chunk = read (fd, (char *) buf + bytes_read, chunk_to_read);
      if (chunk < 0)
        return chunk;
      if (chunk == 0)
        break;
      bytes_read += chunk;
    }

  return bytes_read;
}

/* Return the number of bytes written when we perform the given
   relocation.  */
static int
dump_reloc_size (const struct dump_reloc reloc)
{
  if (sizeof (Lisp_Object) == sizeof (void *))
    return sizeof (Lisp_Object);
  if (reloc.type == RELOC_DUMP_TO_EMACS_PTR_RAW
      || reloc.type == RELOC_DUMP_TO_DUMP_PTR_RAW)
    return sizeof (void *);
  return sizeof (Lisp_Object);
}

static Lisp_Object
dump_make_lv_from_reloc (const uintptr_t dump_base,
			 const struct dump_reloc reloc)
{
  const dump_off reloc_offset = dump_reloc_get_offset (reloc);
  uintptr_t value = dump_read_word_from_dump (dump_base, reloc_offset);
  enum Lisp_Type lisp_type;

  if (RELOC_DUMP_TO_DUMP_LV <= reloc.type
      && reloc.type < RELOC_DUMP_TO_EMACS_LV)
    {
      lisp_type = reloc.type - RELOC_DUMP_TO_DUMP_LV;
      value += dump_base;
      eassert (pdumper_object_p ((void *) value));
    }
  else
    {
      eassert (RELOC_DUMP_TO_EMACS_LV <= reloc.type);
      eassert (reloc.type < RELOC_DUMP_TO_EMACS_LV + 8);
      lisp_type = reloc.type - RELOC_DUMP_TO_EMACS_LV;
      value += emacs_basis ();
    }

  eassert (lisp_type != Lisp_Int0 && lisp_type != Lisp_Int1);

  Lisp_Object lv;
  if (lisp_type == Lisp_Symbol)
    lv = make_lisp_symbol ((void *) value);
  else
    lv = make_lisp_ptr ((void *) value, lisp_type);

  return lv;
}

/* Actually apply a dump relocation.  */
static inline void
dump_do_dump_relocation (const uintptr_t dump_base,
			 const struct dump_reloc reloc)
{
  const dump_off reloc_offset = dump_reloc_get_offset (reloc);

  /* We should never generate a relocation in the cold section.  */
  eassert (reloc_offset < dump_private.header.cold_start);

  switch (reloc.type)
    {
    case RELOC_DUMP_TO_EMACS_PTR_RAW:
      {
        uintptr_t value = dump_read_word_from_dump (dump_base, reloc_offset);
        eassert (dump_reloc_size (reloc) == sizeof (value));
        value += emacs_basis ();
        dump_write_word_to_dump (dump_base, reloc_offset, value);
        break;
      }
    case RELOC_DUMP_TO_DUMP_PTR_RAW:
      {
        uintptr_t value = dump_read_word_from_dump (dump_base, reloc_offset);
        eassert (dump_reloc_size (reloc) == sizeof (value));
        value += dump_base;
        dump_write_word_to_dump (dump_base, reloc_offset, value);
        break;
      }
#ifdef HAVE_NATIVE_COMP
    case RELOC_NATIVE_COMP_UNIT:
      {
	static enum { UNKNOWN, LOCAL_BUILD, INSTALLED } installation_state;
	struct Lisp_Native_Comp_Unit *comp_u
	  = dump_ptr (dump_base, reloc_offset);
	comp_u->lambda_gc_guard_h = CALLN (Fmake_hash_table, QCtest, Qeq);
	if (STRINGP (comp_u->file))
	  error ("trying to load incoherent dumped eln file %s",
		 SSDATA (comp_u->file));

	if (!CONSP (comp_u->file))
	  error ("incoherent compilation unit for dump was dumped");

	/* emacs_execdir is always unibyte, but the file names in
	   comp_u->file could be multibyte, so we need to encode
	   them.  */
	Lisp_Object cu_file1 = ENCODE_FILE (XCAR (comp_u->file));
	Lisp_Object cu_file2 = ENCODE_FILE (XCDR (comp_u->file));
	ptrdiff_t fn1_len = SBYTES (cu_file1), fn2_len = SBYTES (cu_file2);
	Lisp_Object eln_fname;
	char *fndata;

	/* Check just once if this is a local build or Emacs was installed.  */
	/* Can't use expand-file-name here, because we are too early
	   in the startup, and we will crash at least on WINDOWSNT.  */
	if (installation_state == UNKNOWN)
	  {
	    eln_fname = make_uninit_string (execdir_len + fn1_len);
	    fndata = SSDATA (eln_fname);
	    memcpy (fndata, emacs_execdir, execdir_len);
	    memcpy (fndata + execdir_len, SSDATA (cu_file1), fn1_len);
	    if (file_access_p (fndata, F_OK))
	      installation_state = INSTALLED;
	    else
	      {
		eln_fname = make_uninit_string (execdir_len + fn2_len);
		fndata = SSDATA (eln_fname);
		memcpy (fndata, emacs_execdir, execdir_len);
		memcpy (fndata + execdir_len, SSDATA (cu_file2), fn2_len);
		installation_state = LOCAL_BUILD;
	      }
	    fixup_eln_load_path (eln_fname);
	  }
	else
	  {
	    ptrdiff_t fn_len =
	      installation_state == INSTALLED ? fn1_len : fn2_len;
	    Lisp_Object cu_file =
	      installation_state == INSTALLED ? cu_file1 : cu_file2;
	    eln_fname = make_uninit_string (execdir_len + fn_len);
	    fndata = SSDATA (eln_fname);
	    memcpy (fndata, emacs_execdir, execdir_len);
	    memcpy (fndata + execdir_len, SSDATA (cu_file), fn_len);
	  }

	/* FIXME: This records the names of the *.eln files in an
	   unexpanded form, with one or more ".." elements (and on
	   Windows with the first part using backslashes).  The file
	   names are also unibyte.  If we care about this, we need to
	   loop in startup.el over all the preloaded modules and run
	   their file names through expand-file-name and
	   decode-coding-string.  */
	comp_u->file = eln_fname;
	comp_u->handle = dynlib_open_for_eln (SSDATA (eln_fname));
	if (!comp_u->handle)
	  {
	    fprintf (stderr, "Error using execdir %s:\n",
		     emacs_execdir);
	    error ("%s", dynlib_error ());
	  }
	load_comp_unit (comp_u, true, false);
	break;
      }
    case RELOC_NATIVE_SUBR:
      {
	/* When resurrecting from a dump given non all the original
	   native-compiled subrs may be still around we can't rely on
	   a 'top_level_run' mechanism, we revive them one-by-one
	   here.  */
	struct Lisp_Subr *subr = dump_ptr (dump_base, reloc_offset);
	struct Lisp_Native_Comp_Unit *comp_u =
	  XNATIVE_COMP_UNIT (subr->native_comp_u);
	if (!comp_u->handle)
	  error ("NULL handle in compilation unit %s", SSDATA (comp_u->file));
	const char *c_name = subr->native_c_name;
	eassert (c_name);
	void *func = dynlib_sym (comp_u->handle, c_name);
	if (!func)
	  error ("can't find function \"%s\" in compilation unit %s", c_name,
		 SSDATA (comp_u->file));
	subr->function.a0 = func;
	Lisp_Object lambda_data_idx =
	  Fgethash (build_string (c_name), comp_u->lambda_c_name_idx_h, Qnil);
	if (!NILP (lambda_data_idx))
	  {
	    /* This is an anonymous lambda.
	       We must fixup d_reloc so the lambda can be referenced
	       by code.  */
	    Lisp_Object tem;
	    XSETSUBR (tem, subr);
	    Lisp_Object *fixup =
	      &(comp_u->data_relocs[XFIXNUM (lambda_data_idx)]);
	    eassert (EQ (*fixup, Vcomp__hashdollar));
	    *fixup = tem;
	    Fputhash (tem, Qt, comp_u->lambda_gc_guard_h);
	  }
	break;
      }
#endif
    case RELOC_BIGNUM:
      {
        struct Lisp_Bignum *bignum = dump_ptr (dump_base, reloc_offset);
        struct bignum_reload_info reload_info;
	static_assert (sizeof (reload_info) <= sizeof (*bignum_val (bignum)));
        memcpy (&reload_info, bignum_val (bignum), sizeof (reload_info));
        const mp_limb_t *limbs = dump_ptr (dump_base,
					   reload_info.data_location);
        mpz_roinit_n (bignum->value, limbs, reload_info.nlimbs);
        break;
      }
    default: /* Lisp_Object in the dump; precise type in reloc.type */
      {
        Lisp_Object lv = dump_make_lv_from_reloc (dump_base, reloc);
        eassert (dump_reloc_size (reloc) == sizeof (lv));
        dump_write_lv_to_dump (dump_base, reloc_offset, lv);
        break;
      }
    }
}

static void
dump_do_all_dump_reloc_for_phase (const struct dump_header *const header,
				  const uintptr_t dump_base,
				  const enum reloc_phase phase)
{
  struct dump_reloc *r = dump_ptr (dump_base, header->dump_relocs[phase].offset);
  dump_off nr_entries = header->dump_relocs[phase].nr_entries;
  for (dump_off i = 0; i < nr_entries; ++i)
    dump_do_dump_relocation (dump_base, r[i]);
}

static void
dump_do_emacs_relocation (const uintptr_t dump_base,
			  const struct emacs_reloc reloc)
{
  ptrdiff_t pval;
  Lisp_Object lv;

  switch (reloc.type)
    {
    case RELOC_EMACS_COPY_FROM_DUMP:
      eassume (reloc.length > 0);
      memcpy (emacs_ptr_at (reloc.emacs_offset),
              dump_ptr (dump_base, reloc.u.dump_offset),
              reloc.length);
      break;
    case RELOC_EMACS_IMMEDIATE:
      eassume (reloc.length > 0);
      eassume (reloc.length <= sizeof (reloc.u.immediate));
      memcpy (emacs_ptr_at (reloc.emacs_offset),
              &reloc.u.immediate,
              reloc.length);
      break;
    case RELOC_EMACS_DUMP_PTR_RAW:
      pval = reloc.u.dump_offset + dump_base;
      memcpy (emacs_ptr_at (reloc.emacs_offset), &pval, sizeof (pval));
      break;
    case RELOC_EMACS_EMACS_PTR_RAW:
      pval = reloc.u.emacs_offset2 + emacs_basis ();
      memcpy (emacs_ptr_at (reloc.emacs_offset), &pval, sizeof (pval));
      break;
    case RELOC_EMACS_DUMP_LV:
    case RELOC_EMACS_EMACS_LV:
      {
        /* Lisp_Float is the maximum lisp type.  */
        eassume (reloc.length <= Lisp_Float);
        void *obj_ptr = reloc.type == RELOC_EMACS_DUMP_LV
          ? dump_ptr (dump_base, reloc.u.dump_offset)
          : emacs_ptr_at (reloc.u.emacs_offset2);
        if (reloc.length == Lisp_Symbol)
          lv = make_lisp_symbol (obj_ptr);
        else
          lv = make_lisp_ptr (obj_ptr, reloc.length);
        memcpy (emacs_ptr_at (reloc.emacs_offset), &lv, sizeof (lv));
        break;
      }
    default:
      fatal ("unrecognied relocation type %d", (int) reloc.type);
    }
}

static void
dump_do_all_emacs_relocations (const struct dump_header *const header,
			       const uintptr_t dump_base)
{
  const dump_off nr_entries = header->emacs_relocs.nr_entries;
  struct emacs_reloc *r = dump_ptr (dump_base, header->emacs_relocs.offset);
  for (dump_off i = 0; i < nr_entries; ++i)
    dump_do_emacs_relocation (dump_base, r[i]);
}

#ifdef HAVE_NATIVE_COMP
/* Compute and record the directory of the Emacs executable given the
   file name of that executable.  */
static void
pdumper_set_emacs_execdir (char *emacs_executable)
{
  char *p = emacs_executable + strlen (emacs_executable);

  while (p > emacs_executable
	 && !IS_DIRECTORY_SEP (p[-1]))
    --p;
  eassert (p > emacs_executable);
  emacs_execdir = xpalloc (emacs_execdir, &execdir_size,
			   p - emacs_executable + 1 - execdir_size, -1, 1);
  memcpy (emacs_execdir, emacs_executable, p - emacs_executable);
  execdir_len = p - emacs_executable;
  emacs_execdir[execdir_len] = '\0';
}
#endif

enum dump_section
  {
   DS_HOT,
   DS_DISCARDABLE,
   DS_COLD,
   NUMBER_DUMP_SECTIONS,
  };

/* Pointer to a stack variable to avoid having to staticpro it.  */
static Lisp_Object *pdumper_hashes = &zero_vector;

/* Load a dump from DUMP_FILENAME.  Return an error code.

   N.B. We run very early in initialization, so we can't use lisp,
   unwinding, xmalloc, and so on.  */
int
pdumper_load (const char *dump_filename, char *argv0)
{
  intptr_t dump_size;
  struct stat stat;
  uintptr_t dump_base;
  int dump_page_size;
  dump_off adj_discardable_start;

  struct dump_bitset mark_bits[2];
  size_t mark_bits_needed;

  struct dump_header header_buf = { 0 };
  struct dump_header *header = &header_buf;
  struct dump_memory_map sections[NUMBER_DUMP_SECTIONS] = { 0 };

  const struct timespec start_time = current_timespec ();
  char *dump_filename_copy;

  /* Overwriting an initialized Lisp universe will not go well.  */
  eassert (!initialized);

  /* We can load only one dump.  */
  eassert (!dump_loaded_p ());

  int err;
  int dump_fd = emacs_open_noquit (dump_filename, O_RDONLY, 0);
  if (dump_fd < 0)
    {
      err = (errno == ENOENT || errno == ENOTDIR
	     ? PDUMPER_LOAD_FILE_NOT_FOUND
	     : PDUMPER_LOAD_ERROR + errno);
      goto out;
    }

  err = PDUMPER_LOAD_FILE_NOT_FOUND;
  if (sys_fstat (dump_fd, &stat) < 0)
    goto out;

  err = PDUMPER_LOAD_BAD_FILE_TYPE;
  if (stat.st_size > INTPTR_MAX)
    goto out;
  dump_size = (intptr_t) stat.st_size;

  err = PDUMPER_LOAD_BAD_FILE_TYPE;
  if (dump_size < sizeof (*header))
    goto out;

  err = PDUMPER_LOAD_BAD_FILE_TYPE;
  if (dump_read_all (dump_fd,
                     header,
                     sizeof (*header)) < sizeof (*header))
    goto out;

  if (memcmp (header->magic, dump_magic, sizeof (dump_magic)) != 0)
    {
      if (header->magic[0] == '!'
	  && (header->magic[0] = dump_magic[0],
	      memcmp (header->magic, dump_magic, sizeof (dump_magic)) == 0))
        {
          err = PDUMPER_LOAD_FAILED_DUMP;
          goto out;
        }
      err = PDUMPER_LOAD_BAD_FILE_TYPE;
      goto out;
    }

  err = PDUMPER_LOAD_VERSION_MISMATCH;
  static_assert (sizeof (header->fingerprint) == sizeof (fingerprint));
  unsigned char desired[sizeof fingerprint];
  for (int i = 0; i < sizeof fingerprint; i++)
    desired[i] = fingerprint[i];
  if (memcmp (header->fingerprint, desired, sizeof desired) != 0)
    {
      dump_fingerprint (stderr, "desired fingerprint", desired);
      dump_fingerprint (stderr, "found fingerprint", header->fingerprint);
      goto out;
    }

  /* FIXME: The comment at the start of this function says it should
     not use xmalloc, but xstrdup calls xmalloc.  Either fix the
     comment or fix the following code.  */
  dump_filename_copy = xstrdup (dump_filename);

  err = PDUMPER_LOAD_OOM;

  adj_discardable_start = header->discardable_start;
  dump_page_size = dump_get_max_page_size ();
  /* Snap to next page boundary.  */
  adj_discardable_start = ROUNDUP (adj_discardable_start, dump_page_size);
  eassert (adj_discardable_start % dump_page_size == 0);
  eassert (adj_discardable_start <= header->cold_start);

  sections[DS_HOT].spec = (struct dump_memory_map_spec)
    {
     .fd = dump_fd,
     .size = adj_discardable_start,
     .offset = 0,
     .protection = DUMP_MEMORY_ACCESS_READWRITE,
    };

  sections[DS_DISCARDABLE].spec = (struct dump_memory_map_spec)
    {
     .fd = dump_fd,
     .size = header->cold_start - adj_discardable_start,
     .offset = adj_discardable_start,
     .protection = DUMP_MEMORY_ACCESS_READWRITE,
    };

  sections[DS_COLD].spec = (struct dump_memory_map_spec)
    {
     .fd = dump_fd,
     .size = dump_size - header->cold_start,
     .offset = header->cold_start,
     .protection = DUMP_MEMORY_ACCESS_READWRITE,
    };

  if (!dump_mmap_contiguous (sections, ARRAYELTS (sections)))
    goto out;

  err = PDUMPER_LOAD_ERROR;
  dump_base = (uintptr_t) sections[DS_HOT].mapping;

#if !USE_LSB_TAG
  /* The dump may have been mapped at a location that does not admit of
     representation as Lisp_Objects.  Abort in this case.  */
  if ((dump_base + dump_size) & ~VALMASK)
    {
      fprintf (stderr,
	       "Failed to load dump file: 0x%p+0x%p & ~0x%p != 0\n",
	       (void *) dump_base, (void *) dump_size,
	       (void *) (uintptr_t) VALMASK);
      goto out;
    }
#endif /* !USE_LSB_TAG */

  mark_bits_needed
    = divide_round_up (header->discardable_start, DUMP_ALIGNMENT);
  if (!dump_bitsets_init (mark_bits, mark_bits_needed))
    goto out;

  /* Point of no return.  */
  err = PDUMPER_LOAD_SUCCESS;
  gflags.dumped_with_pdumper = true;
  dump_private.header = *header;
  dump_private.mark_bits = mark_bits[0];
  dump_private.last_mark_bits = mark_bits[1];
  dump_public.start = dump_base;
  dump_public.end = dump_public.start + dump_size;

  dump_do_all_dump_reloc_for_phase (header, dump_base, EARLY_RELOCS);
  dump_do_all_emacs_relocations (header, dump_base);

  dump_mmap_discard_contents (&sections[DS_DISCARDABLE]);
  for (int i = 0; i < ARRAYELTS (sections); ++i)
    dump_mmap_reset (&sections[i]);

  Lisp_Object hashes = zero_vector;
  if (header->hash_list)
    {
      struct Lisp_Vector *hash_tables
	= (struct Lisp_Vector *) (dump_base + header->hash_list);
      hashes = make_lisp_ptr (hash_tables, Lisp_Vectorlike);
    }

  pdumper_hashes = &hashes;
  /* Run the functions Emacs registered for doing post-dump-load
     initialization.  */
  for (int i = 0; i < nr_dump_hooks; ++i)
    dump_hooks[i] ();

#ifdef HAVE_NATIVE_COMP
  pdumper_set_emacs_execdir (argv0);
#else
  (void) argv0;
#endif

  dump_do_all_dump_reloc_for_phase (header, dump_base, LATE_RELOCS);
  dump_do_all_dump_reloc_for_phase (header, dump_base, VERY_LATE_RELOCS);

  /* Run the functions Emacs registered for doing post-dump-load
     initialization.  */
  for (int i = 0; i < nr_dump_late_hooks; ++i)
    dump_late_hooks[i] ();

  initialized = true;

  struct timespec load_timespec =
    timespec_sub (current_timespec (), start_time);
  dump_private.load_time = timespectod (load_timespec);
  dump_private.dump_filename = dump_filename_copy;

 out:
  for (int i = 0; i < ARRAYELTS (sections); ++i)
    dump_mmap_release (&sections[i]);
  if (dump_fd >= 0)
    emacs_close (dump_fd);
  return err;
}

/* Prepend the Emacs startup directory to dump_filename, if that is
   relative, so that we could later make it absolute correctly.  */
void
pdumper_record_wd (const char *wd)
{
  if (wd && !file_name_absolute_p (dump_private.dump_filename))
    {
      char *dfn = xmalloc (strlen (wd) + 1
			   + strlen (dump_private.dump_filename) + 1);
      splice_dir_file (dfn, wd, dump_private.dump_filename);
      xfree (dump_private.dump_filename);
      dump_private.dump_filename = dfn;
    }
}

DEFUN ("pdumper-stats", Fpdumper_stats, Spdumper_stats, 0, 0, 0,
       doc: /* Return statistics about portable dumping used by this session.
If this Emacs session was started from a dump file,
the return value is an alist of the form:

  ((dumped-with-pdumper . t) (load-time . TIME) (dump-file-name . FILE))

where TIME is the time in seconds it took to restore Emacs state
from the dump file, and FILE is the name of the dump file.
Value is nil if this session was not started using a dump file.*/)
     (void)
{
  if (!dumped_with_pdumper_p ())
    return Qnil;

  Lisp_Object dump_fn;
#ifdef WINDOWSNT
  char dump_fn_utf8[MAX_UTF8_PATH];
  if (filename_from_ansi (dump_private.dump_filename, dump_fn_utf8) == 0)
    dump_fn = DECODE_FILE (build_unibyte_string (dump_fn_utf8));
  else
    dump_fn = build_unibyte_string (dump_private.dump_filename);
#else
  dump_fn = DECODE_FILE (build_unibyte_string (dump_private.dump_filename));
#endif

  dump_fn = Fexpand_file_name (dump_fn, Qnil);

  return list3 (Fcons (Qdumped_with_pdumper, Qt),
		Fcons (Qload_time, make_float (dump_private.load_time)),
		Fcons (Qdump_file_name, dump_fn));
}

static void
thaw_hash_tables (void)
{
  Lisp_Object hash_tables = *pdumper_hashes;
  for (ptrdiff_t i = 0; i < ASIZE (hash_tables); i++)
    hash_table_thaw (AREF (hash_tables, i));
}

#endif /* HAVE_PDUMPER */


void
init_pdumper_once (void)
{
#ifdef HAVE_PDUMPER
  pdumper_do_now_and_after_load (thaw_hash_tables);
#endif
}

void
syms_of_pdumper (void)
{
#ifdef HAVE_PDUMPER
  unsigned char desired[sizeof fingerprint];
  int i;
  char hexbuf[2 * sizeof fingerprint];

  defsubr (&Sdump_emacs_portable);
  defsubr (&Sdump_emacs_portable__sort_predicate);
  defsubr (&Sdump_emacs_portable__sort_predicate_copied);
  DEFSYM (Qdump_emacs_portable__sort_predicate,
          "dump-emacs-portable--sort-predicate");
  DEFSYM (Qdump_emacs_portable__sort_predicate_copied,
          "dump-emacs-portable--sort-predicate-copied");
  DEFSYM (Qdumped_with_pdumper, "dumped-with-pdumper");
  DEFSYM (Qload_time, "load-time");
  DEFSYM (Qdump_file_name, "dump-file-name");
  DEFSYM (Qafter_pdump_load_hook, "after-pdump-load-hook");
  defsubr (&Spdumper_stats);

  for (i = 0; i < sizeof fingerprint; i++)
    desired[i] = fingerprint[i];

  hexbuf_digest (hexbuf, desired, sizeof desired);

  DEFVAR_LISP ("pdumper-fingerprint", Vpdumper_fingerprint,
	       doc: /* The fingerprint of this Emacs binary.
It is a string that is supposed to be unique to each build of
Emacs.  */);
  Vpdumper_fingerprint = make_unibyte_string ((char *) hexbuf,
					      sizeof hexbuf);
#endif /* HAVE_PDUMPER */
}
