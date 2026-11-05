/* util.h -- small string helpers (also built on the PC for the tests) */
#ifndef UTIL_H
#define UTIL_H

#include <stdint.h>

int   u_strlen(const char *s);
char *u_strcpy(char *d, const char *s);               /* returns the end of d */
char *u_strncpy(char *d, const char *s, int n);       /* copies at most n chars, always terminates */
int   u_stricmp(const char *a, const char *b);
char *u_utoa(char *d, uint32_t v);                     /* decimal, returns the end of d */
void  u_memset(void *d, int c, uint32_t n);
void  u_memcpy(void *d, const void *s, uint32_t n);
int   u_memcmp(const void *a, const void *b, uint32_t n);

#endif
