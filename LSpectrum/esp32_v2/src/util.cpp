/* util.c -- small string helpers */
#include "util.h"

int u_strlen(const char *s)
{
    int n = 0;
    while (s[n]) n++;
    return n;
}

char *u_strcpy(char *d, const char *s)
{
    while ((*d = *s++) != 0) d++;
    return d;
}

char *u_strncpy(char *d, const char *s, int n)
{
    while (n-- > 0 && *s) *d++ = *s++;
    *d = 0;
    return d;
}

static int lower(int c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }

int u_stricmp(const char *a, const char *b)
{
    while (*a && lower(*a) == lower(*b)) { a++; b++; }
    return lower((unsigned char)*a) - lower((unsigned char)*b);
}

char *u_utoa(char *d, uint32_t v)
{
    char t[11];
    int n = 0;
    do { t[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) *d++ = t[--n];
    *d = 0;
    return d;
}

void u_memset(void *d, int c, uint32_t n)
{
    uint8_t *p = (uint8_t *)d;
    while (n--) *p++ = (uint8_t)c;
}

void u_memcpy(void *d, const void *s, uint32_t n)
{
    uint8_t *p = (uint8_t *)d;
    const uint8_t *q = (const uint8_t *)s;
    while (n--) *p++ = *q++;
}

int u_memcmp(const void *a, const void *b, uint32_t n)
{
    const uint8_t *p = (const uint8_t *)a, *q = (const uint8_t *)b;
    for (; n; n--, p++, q++)
        if (*p != *q) return *p - *q;
    return 0;
}
