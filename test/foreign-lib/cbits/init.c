#include "HsFFI.h"

void hsflib_init(void)
{
  static char *argv[] = { "hsflib", 0 }, **argv_ = argv;
  static int argc = 1;
  hs_init(&argc, &argv_);
}

void hsflib_exit(void)
{
  hs_exit();
}
