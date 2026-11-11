/* util.c -- small string helpers */
#include "util.h"

/* distance between an upper-case letter and its lower-case form in ASCII */
#define ASCII_CASE_OFFSET 32
/* number base of u_utoa */
#define DECIMAL_BASE 10
/* digits of the largest 32-bit number, plus the terminator */
#define UTOA_DIGITS_MAX 11

/* length of a zero-terminated string */
int32_t u_strlen(const char *pc_str)
{
    int32_t i32_len;

    i32_len = 0;
/* count up to the terminator */
    while (pc_str[i32_len] != 0)
    {
        i32_len++;
    }
    return i32_len;
}

/* copy a string; returns the end of the destination (its terminator) */
char *u_strcpy(char *pc_dst, const char *pc_src)
{
/* the terminator is copied too, but the pointer stays on it */
    while (*pc_src != 0)
    {
        *pc_dst = *pc_src;
/* both pointers on */
        pc_dst++;
        pc_src++;
    }
/* terminate the destination */
    *pc_dst = 0;
    return pc_dst;
}

/* copy at most i32_max characters and always terminate; returns the end */
char *u_strncpy(char *pc_dst, const char *pc_src, int32_t i32_max)
{
/* stop at the limit or at the end of the source */
    while ((i32_max > 0) && (*pc_src != 0))
    {
        *pc_dst = *pc_src;
/* both pointers on */
        pc_dst++;
        pc_src++;
/* one character less is allowed */
        i32_max--;
    }
/* terminate the destination */
    *pc_dst = 0;
    return pc_dst;
}

/* lower-case form of an ASCII character */
static int32_t lower(int32_t i32_char)
{
    int32_t i32_result;

    i32_result = i32_char;
/* only the letters A to Z change */
    if ((i32_char >= 'A') && (i32_char <= 'Z'))
    {
        i32_result = i32_char + ASCII_CASE_OFFSET;
    }
    return i32_result;
}

/* compare two strings without regard to case: 0 = equal */
int32_t u_stricmp(const char *pc_a, const char *pc_b)
{
    int32_t i32_diff;

    i32_diff = 0;
/* skip the part that is equal */
    while ((*pc_a != 0) && (lower(*pc_a) == lower(*pc_b)))
    {
        pc_a++;
        pc_b++;
    }
/* the first different pair decides */
    i32_diff = lower((uint8_t)*pc_a) - lower((uint8_t)*pc_b);
    return i32_diff;
}

/* write a number in decimal; returns the end of the destination */
char *u_utoa(char *pc_dst, uint32_t ui32_value)
{
/* local variables */
    char ac_digits[UTOA_DIGITS_MAX];
    int32_t i32_count;

    i32_count = 0;
/* the digits come out last one first */
    do
    {
        ac_digits[i32_count] = (char)('0' + (ui32_value % DECIMAL_BASE));
        i32_count++;
/* next digit */
        ui32_value /= DECIMAL_BASE;
    } while (ui32_value != 0);
/* write them in reading order */
    while (i32_count != 0)
    {
        i32_count--;
        *pc_dst = ac_digits[i32_count];
/* next place in the destination */
        pc_dst++;
    }
/* terminate the destination */
    *pc_dst = 0;
    return pc_dst;
}

/* fill ui32_count bytes with one value */
void u_memset(void *p_dst, int32_t i32_value, uint32_t ui32_count)
{
    uint8_t *pui8_dst;

    pui8_dst = (uint8_t *)p_dst;
/* byte by byte */
    while (ui32_count != 0)
    {
        *pui8_dst = (uint8_t)i32_value;
        pui8_dst++;
/* one byte less to do */
        ui32_count--;
    }
}

/* copy ui32_count bytes (the areas must not overlap) */
void u_memcpy(void *p_dst, const void *p_src, uint32_t ui32_count)
{
/* local variables */
    uint8_t *pui8_dst;
    const uint8_t *pui8_src;

/* start values */
    pui8_dst = (uint8_t *)p_dst;
    pui8_src = (const uint8_t *)p_src;
/* byte by byte */
    while (ui32_count != 0)
    {
        *pui8_dst = *pui8_src;
        pui8_dst++;
/* next source byte */
        pui8_src++;
        ui32_count--;
    }
}

/* compare ui32_count bytes: 0 = equal, else the first difference */
int32_t u_memcmp(const void *p_a, const void *p_b, uint32_t ui32_count)
{
/* local variables */
    const uint8_t *pui8_a;
    const uint8_t *pui8_b;
    int32_t i32_diff;

/* start values */
    pui8_a = (const uint8_t *)p_a;
    pui8_b = (const uint8_t *)p_b;
/* equal until a difference is found */
    i32_diff = 0;
    while ((ui32_count != 0) && (i32_diff == 0))
    {
/* a difference ends the loop */
        if (*pui8_a != *pui8_b)
        {
            i32_diff = (int32_t)*pui8_a - (int32_t)*pui8_b;
        }
/* next pair */
        pui8_a++;
        pui8_b++;
        ui32_count--;
    }
/* 0, or the first difference */
    return i32_diff;
}
