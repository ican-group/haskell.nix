#include <stdio.h>

extern void hsflib_init(void);
extern void hsflib_exit(void);
extern int hsflib_add(int, int);

int main(void)
{
  int r;
  hsflib_init();
  r = hsflib_add(2, 40);
  printf("hsflib_add 2 40 = %d\n", r);
  hsflib_exit();
  return r == 42 ? 0 : 1;
}
