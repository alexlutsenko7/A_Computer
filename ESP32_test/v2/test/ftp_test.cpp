/* ftp_test.cpp -- PC test of the FTP server (ESP32/v2/src/ftp.cpp): the server on this PC, a folder */
/* as its root; ftp_client.py starts it, talks to it with Python's FTP client and ends it. */
/* ftp_test.exe ROOT PORT */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
/* Windows: sockets, the clock, Sleep */
#include <winsock2.h>
#include <windows.h>
#include "../../../ESP32/v2/src/ftp.h"

/* flags as numbers */
#define YES 1
/* the arguments: program, root folder, port */
#define ARG_COUNT 3
#define ARG_ROOT 1
#define ARG_PORT 2
/* the socket library's version 2.2 */
#define WSA_VERSION 0x0202
/* the rest when there is no work, in milliseconds */
#define IDLE_MS 1

/* the server's clock */
uint32_t ftp_ms(void)
{
/* local variables */
    uint32_t ui32_ms;

    ui32_ms = (uint32_t)GetTickCount();
    return ui32_ms;
}

/* the server runs until the test ends this program */
int main(int argc, char **ppc_argv)
{
/* local variables */
    WSADATA s_wsa;
    int32_t i32_result;

/* start values */
    i32_result = YES;
    if ((argc == ARG_COUNT) && (WSAStartup(WSA_VERSION, &s_wsa) == 0))
    {
        if (ftp_start(ppc_argv[ARG_ROOT], (uint32_t)atoi(ppc_argv[ARG_PORT])) == 0)
        {
/* the test waits for this line */
            printf("ftp_test: running\n");
            fflush(stdout);
/* until the program is ended from outside */
            while (true)
            {
                if (ftp_poll() == 0)
                {
                    Sleep(IDLE_MS);
                }
            }
        }
    }
/* only reached when the server could not start */
    printf("ftp_test: could not start\n");
    return i32_result;
}
