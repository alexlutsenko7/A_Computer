/* util.h -- small string helpers (also built on the PC for the tests) */
#ifndef UTIL_H
#define UTIL_H

#include <stdint.h>

/* length of a zero-terminated string */
int32_t u_strlen(const char *pc_str);
/* copy a string; returns the end of the destination */
char *u_strcpy(char *pc_dst, const char *pc_src);
/* copy at most i32_max characters, always terminates; returns the end */
char *u_strncpy(char *pc_dst, const char *pc_src, int32_t i32_max);
/* compare two strings without regard to case */
int32_t u_stricmp(const char *pc_a, const char *pc_b);
/* write a number in decimal; returns the end of the destination */
char *u_utoa(char *pc_dst, uint32_t ui32_value);
/* fill ui32_count bytes with one value */
void u_memset(void *p_dst, int32_t i32_value, uint32_t ui32_count);
/* copy ui32_count bytes */
void u_memcpy(void *p_dst, const void *p_src, uint32_t ui32_count);
/* compare ui32_count bytes; 0 = equal */
int32_t u_memcmp(const void *p_a, const void *p_b, uint32_t ui32_count);

#endif
