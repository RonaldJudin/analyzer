// PARAM: --set "ana.activated[+]" termination --enable warn.debug --set ana.activated[+] apron --enable ana.int.interval --set ana.apron.domain polyhedra
#include <stdio.h>

int main()
{
    int i;

    for (i = 1; i <= 10; i++) // TERM
    {
        printf("%d\n", i);
    }

    return 0;
}
