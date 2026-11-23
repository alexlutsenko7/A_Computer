/* ftp.cpp -- an FTP server for the SD card (ftp.h). */
/* */
/* One task runs everything: ftp_poll() takes new clients, reads their commands and moves a piece */
/* of every transfer, so no call waits long and several clients are served side by side. All */
/* sockets are non-blocking. A client's paths are made clean first ("." and ".." taken out), so */
/* nothing above the root folder can be reached. */
/* */
/* Data connections: passive (PASV / EPSV: we listen on a port the system picks, for that one */
/* transfer) and active (PORT: we connect to the client; always to the address the control */
/* connection came from). Transfers are binary whatever TYPE says. */
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
/* memory, texts, dates */
#include <stdlib.h>
#include <string.h>
#include <time.h>
/* error numbers, files */
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
/* folders, a file's facts */
#include <dirent.h>
#include <sys/stat.h>
#ifdef _WIN32
/* the PC test (Windows sockets) */
#include <winsock2.h>
#include <ws2tcpip.h>
#else
/* the ESP32 (lwIP) */
#include <lwip/sockets.h>
#include <sys/select.h>
#endif
/* the server's own calls */
#include "ftp.h"

/* what differs between the two socket libraries */
#ifdef _WIN32
/* a call would have had to wait */
#define SOCK_AGAIN() (WSAGetLastError() == WSAEWOULDBLOCK)
/* a socket's settings: the call and its argument */
#define SOCK_IOCTL(s, c, p) ioctlsocket(s, c, (u_long *)(p))
/* a new folder; files are opened without text translation */
#define MAKE_DIR(p) mkdir(p)
#define OPEN_BINARY O_BINARY
#else
/* a call would have had to wait */
#define SOCK_AGAIN() ((errno == EAGAIN) || (errno == EWOULDBLOCK) || (errno == EINPROGRESS))
/* a socket's settings: the call and its argument */
#define SOCK_IOCTL(s, c, p) lwip_ioctl(s, c, (void *)(p))
/* a new folder; files are opened without text translation */
#define MAKE_DIR(p) mkdir(p, DIR_MODE)
#define OPEN_BINARY 0
#endif

/* flags as numbers */
#define YES 1
/* no socket, no file */
#define NO_SOCK (-1)
#define NO_FILE (-1)
/* access rights of new files and folders (the card's file system has none) */
#define FILE_MODE 0666
#define DIR_MODE 0777
/* a command line, a client's path, the root folder's name, both together */
#define LINE_BUF 512
#define PATH_BUF 256
#define ROOT_BUF 64
/* root folder and path together */
#define REAL_BUF (ROOT_BUF + PATH_BUF)
/* a folder's entry with its folder; one line of a listing; an answer */
#define ENTRY_BUF (REAL_BUF + PATH_BUF)
#define LIST_LINE_BUF 400
#define REPLY_BUF 600
/* a client's transfer buffer (a multiple of the card's sector) */
#define XFER_BUF_SIZE 16384
/* connections that may wait on a listening port */
#define BACKLOG 2
/* letters of a command's name, and with the terminator */
#define VERB_MAX 4
#define VERB_BUF 5
/* how the next data connection is made */
#define DATA_NONE 0
#define DATA_PASSIVE 1
#define DATA_ACTIVE 2
/* a transfer's kind */
#define XFER_NONE 0
#define XFER_LIST 1
/* a file to the client, a file from it */
#define XFER_RETR 2
#define XFER_STOR 3
/* a transfer's state: the data connection is not there yet, data moves */
#define STATE_WAIT 0
#define STATE_RUN 1
/* what a path is */
#define KIND_NONE 0
#define KIND_FILE 1
#define KIND_DIR 2
/* the data connection must stand within this time; sending waits so long for the client; */
/* an upload without data ends after this time; a client without commands is dropped */
#define DATA_WAIT_MS 15000u
#define SEND_MS 10000u
/* the limits for an upload without data and for a silent client */
#define STALL_MS 60000u
#define IDLE_MS 600000u
/* one wait for room to send, in microseconds */
#define SEND_STEP_US 20000
/* telnet's "command follows" byte (clients put it in front of ABOR) */
#define TELNET_IAC 0xFFu
/* the bytes of an address, the two bytes of a port */
#define IP_BYTES 4
/* the bytes after the first */
#define IP_BYTE_1 1
#define IP_BYTE_2 2
#define IP_BYTE_3 3
/* the numbers of PORT's argument, the port's two among them */
#define PORT_FIELDS 6
#define PORT_HIGH 4
#define PORT_LOW 5
/* a port's high byte in a number, one byte of it */
#define PORT_SHIFT 8
#define PORT_BYTE_MASK 0xFFu
/* bytes of a kilobyte as a shift; years count from 1900 */
#define KB_SHIFT 10
#define TM_YEAR_BASE 1900
/* tm's months count from 0 */
#define TM_MONTH_BASE 1
#define MONTHS 12

/* the commands; those from CMD_RETR to CMD_MDTM need a name */
enum
{
    CMD_USER,
    CMD_PASS,
    CMD_SYST,
    CMD_FEAT,
    CMD_PWD,
    CMD_XPWD,
    CMD_CWD,
    CMD_XCWD,
    CMD_CDUP,
    CMD_XCUP,
    CMD_TYPE,
    CMD_MODE,
    CMD_STRU,
    CMD_NOOP,
    CMD_OPTS,
    CMD_ALLO,
    CMD_PASV,
    CMD_EPSV,
    CMD_PORT,
    CMD_REST,
    CMD_LIST,
    CMD_NLST,
    CMD_RETR,
    CMD_STOR,
    CMD_APPE,
    CMD_DELE,
    CMD_MKD,
    CMD_XMKD,
    CMD_RMD,
    CMD_XRMD,
    CMD_RNFR,
    CMD_RNTO,
    CMD_SIZE,
    CMD_MDTM,
    CMD_ABOR,
    CMD_STAT,
    CMD_QUIT,
    CMD_COUNT
};

/* their names, in the same order */
static const char *const g_apc_verb[CMD_COUNT] = {
    "USER", "PASS", "SYST", "FEAT", "PWD", "XPWD", "CWD", "XCWD", "CDUP", "XCUP", "TYPE", "MODE", "STRU",
    "NOOP", "OPTS", "ALLO", "PASV", "EPSV", "PORT", "REST", "LIST", "NLST", "RETR", "STOR", "APPE", "DELE",
    "MKD", "XMKD", "RMD", "XRMD", "RNFR", "RNTO", "SIZE", "MDTM", "ABOR", "STAT", "QUIT"
};
/* the months of a listing */
static const char *const g_apc_month[MONTHS] = {
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
};

/* a client */
typedef struct
{
/* in use, leaving; the control connection, the data connection, the passive listening socket */
    int32_t i32_used;
    int32_t i32_quit;
/* the three sockets */
    int32_t i32_ctrl;
    int32_t i32_data;
    int32_t i32_pasv;
/* the command line being received: its length, 1 = a whole line waits, 1 = a telnet byte follows */
    char ac_line[LINE_BUF];
    int32_t i32_len;
/* the line's two flags */
    int32_t i32_ready;
    int32_t i32_iac;
/* the current folder, the name RNFR gave (empty: none) */
    char ac_cwd[PATH_BUF];
    char ac_from[PATH_BUF];
/* how the next data connection is made (DATA_*), the client's port for the active way */
    int32_t i32_mode;
    uint32_t ui32_port;
/* the transfer: kind (XFER_*), state (STATE_*), 1 = a listing of names only */
    int32_t i32_xfer;
    int32_t i32_state;
    int32_t i32_names;
/* its file, its folder and the folder's name; where the next file transfer starts (REST) */
    int32_t i32_fd;
    DIR *ps_dir;
    char ac_dir[REAL_BUF];
/* REST's position */
    uint32_t ui32_rest;
/* its buffer; the bytes in it that still have to go to the client (where, how many); 1 = the */
/* file or folder has been read to its end */
    uint8_t *pui8_buf;
    int32_t i32_pend_at;
    int32_t i32_pend_len;
/* the end was reached */
    int32_t i32_end;
/* when something last happened */
    uint32_t ui32_time;
} FTP_SES;

/* the clients, their transfer buffers (both allocated while the server runs) */
static FTP_SES *g_ps_ses;
static uint8_t *g_pui8_buf;
/* 1 = something was done in this pass of ftp_poll */
static int32_t g_i32_work;
/* the root folder; the socket that waits for clients */
static char g_ac_root[ROOT_BUF];
static int32_t g_i32_listen = NO_SOCK;
/* files and bytes received and sent, the last action */
static uint32_t g_ui32_files_in;
static uint32_t g_ui32_files_out;
/* the bytes, the text of the last action */
static uint64_t g_ui64_bytes_in;
static uint64_t g_ui64_bytes_out;
static char g_ac_last[FTP_TEXT_BUF];

/* sockets */

/* a socket's calls return at once from now on */
static void sock_nonblock(int32_t i32_sock)
{
/* local variables */
    uint32_t ui32_on;

/* start values */
    ui32_on = YES;
    (void)SOCK_IOCTL(i32_sock, FIONBIO, &ui32_on);
}

/* close a socket (NO_SOCK: nothing) and forget it */
static void sock_close(int32_t *pi32_sock)
{
    if (*pi32_sock != NO_SOCK)
    {
        (void)closesocket(*pi32_sock);
    }
/* none now */
    *pi32_sock = NO_SOCK;
}

/* a socket that waits for connections on a port (0: one the system picks); the port is given */
/* back. NO_SOCK = it could not be made */
static int32_t sock_listen(uint32_t ui32_port, uint32_t *pui32_port)
{
/* local variables */
    struct sockaddr_in s_where;
    socklen_t s_len;
/* the socket, the option's value */
    int32_t i32_sock;
    int32_t i32_on;

/* start values */
    memset(&s_where, 0, sizeof s_where);
    s_len = (socklen_t)sizeof s_where;
    i32_on = YES;
/* a TCP socket */
    i32_sock = (int32_t)socket(AF_INET, SOCK_STREAM, 0);
    if (i32_sock >= 0)
    {
/* a fixed port can be taken again right after a restart */
        if (ui32_port != 0)
        {
            (void)setsockopt(i32_sock, SOL_SOCKET, SO_REUSEADDR, (const char *)&i32_on, (socklen_t)sizeof i32_on);
        }
/* any of our addresses */
        s_where.sin_family = AF_INET;
        s_where.sin_addr.s_addr = htonl(INADDR_ANY);
        s_where.sin_port = htons((uint16_t)ui32_port);
/* bound and listening, or no socket */
        if ((bind(i32_sock, (struct sockaddr *)&s_where, s_len) == 0) && (listen(i32_sock, BACKLOG) == 0))
        {
            sock_nonblock(i32_sock);
/* the port it got */
            (void)getsockname(i32_sock, (struct sockaddr *)&s_where, &s_len);
            *pui32_port = ntohs(s_where.sin_port);
        }
        else
        {
/* the port could not be had */
            sock_close(&i32_sock);
        }
    }
    else
    {
/* no socket was free */
        i32_sock = NO_SOCK;
    }
    return i32_sock;
}

/* a connection that waits on a listening socket, or NO_SOCK */
static int32_t sock_accept(int32_t i32_listen)
{
/* local variables */
    int32_t i32_sock;

/* start values */
    i32_sock = (int32_t)accept(i32_listen, NULL, NULL);
    if (i32_sock >= 0)
    {
/* as all our sockets */
        sock_nonblock(i32_sock);
    }
    else
    {
/* nobody waits */
        i32_sock = NO_SOCK;
    }
    return i32_sock;
}

/* send all the bytes, waiting for the other side as long as it keeps taking them: 0 = ok */
static int32_t sock_send(int32_t i32_sock, const uint8_t *pui8_data, uint32_t ui32_len)
{
/* local variables */
    fd_set s_write;
    struct timeval s_wait;
/* bytes sent so far, when the last ones went */
    uint32_t ui32_sent;
    uint32_t ui32_start;
/* bytes taken by one call, the result */
    int32_t i32_count;
    int32_t i32_result;

/* start values */
    ui32_sent = 0;
/* the waiting time runs from now */
    ui32_start = ftp_ms();
    i32_count = 0;
    i32_result = 0;
/* piece by piece */
    while ((ui32_sent < ui32_len) && (i32_result == 0))
    {
        i32_count = (int32_t)send(i32_sock, (const char *)(pui8_data + ui32_sent), (int)(ui32_len - ui32_sent), 0);
        if (i32_count > 0)
        {
/* some went: the waiting time starts again */
            ui32_sent += (uint32_t)i32_count;
            ui32_start = ftp_ms();
        }
        else if (SOCK_AGAIN() && ((ftp_ms() - ui32_start) < SEND_MS))
        {
/* no room now: wait a moment for some */
            FD_ZERO(&s_write);
            FD_SET(i32_sock, &s_write);
/* for one step's time */
            s_wait.tv_sec = 0;
            s_wait.tv_usec = SEND_STEP_US;
/* until there is room or the time is over */
            (void)select(i32_sock + YES, NULL, &s_write, NULL, &s_wait);
        }
        else
        {
/* the connection is gone, or the other side takes nothing */
            i32_result = -YES;
        }
    }
    return i32_result;
}

/* send what the other side takes now: the number of bytes (0 = none now), below 0 = the */
/* connection has ended */
static int32_t sock_send_some(int32_t i32_sock, const uint8_t *pui8_data, int32_t i32_len)
{
/* local variables */
    int32_t i32_count;
    int32_t i32_result;

/* start values */
    i32_result = -YES;
    i32_count = (int32_t)send(i32_sock, (const char *)pui8_data, (int)i32_len, 0);
    if (i32_count >= 0)
    {
/* all or a part went */
        i32_result = i32_count;
    }
    else if (SOCK_AGAIN())
    {
/* no room now */
        i32_result = 0;
    }
    else
    {
/* closed by the other side, or broken */
    }
    return i32_result;
}

/* take the bytes that wait: their number, 0 = none now, below 0 = the connection has ended */
static int32_t sock_recv(int32_t i32_sock, uint8_t *pui8_data, int32_t i32_max)
{
/* local variables */
    int32_t i32_count;
    int32_t i32_result;

/* start values */
    i32_result = -YES;
    i32_count = (int32_t)recv(i32_sock, (char *)pui8_data, (int)i32_max, 0);
    if (i32_count > 0)
    {
/* some bytes */
        i32_result = i32_count;
    }
    else if ((i32_count < 0) && SOCK_AGAIN())
    {
/* nothing waits */
        i32_result = 0;
    }
    else
    {
/* closed by the other side, or broken */
    }
    return i32_result;
}

/* start a connection to the control connection's other end, on a port of its choice: the */
/* socket, or NO_SOCK */
static int32_t sock_connect(int32_t i32_ctrl, uint32_t ui32_port)
{
/* local variables */
    struct sockaddr_in s_where;
    socklen_t s_len;
    int32_t i32_sock;

/* start values */
    memset(&s_where, 0, sizeof s_where);
    s_len = (socklen_t)sizeof s_where;
    i32_sock = NO_SOCK;
/* the client's address */
    if (getpeername(i32_ctrl, (struct sockaddr *)&s_where, &s_len) == 0)
    {
/* a socket of our own for it */
        i32_sock = (int32_t)socket(AF_INET, SOCK_STREAM, 0);
        if (i32_sock >= 0)
        {
            sock_nonblock(i32_sock);
/* the same address, the port asked for */
            s_where.sin_port = htons((uint16_t)ui32_port);
/* the connection is made while we do other things */
            if (connect(i32_sock, (struct sockaddr *)&s_where, s_len) != 0)
            {
                if (!SOCK_AGAIN())
                {
/* refused at once */
                    sock_close(&i32_sock);
                }
            }
        }
        else
        {
/* no socket was free */
            i32_sock = NO_SOCK;
        }
    }
    return i32_sock;
}

/* a connection that was started: 1 = it stands, 0 = not yet, below 0 = it failed */
static int32_t sock_connected(int32_t i32_sock)
{
/* local variables */
    fd_set s_write;
    fd_set s_error;
    struct timeval s_wait;
/* the length of the error's value */
    socklen_t s_len;
/* the socket's error, the result */
    int32_t i32_error;
    int32_t i32_result;

/* start values */
    s_len = (socklen_t)sizeof i32_error;
    i32_error = 0;
    i32_result = 0;
/* writable = connected, an error = refused; no waiting */
    FD_ZERO(&s_write);
    FD_SET(i32_sock, &s_write);
/* and the errors */
    FD_ZERO(&s_error);
    FD_SET(i32_sock, &s_error);
/* at once */
    s_wait.tv_sec = 0;
    s_wait.tv_usec = 0;
    if (select(i32_sock + YES, NULL, &s_write, &s_error, &s_wait) > 0)
    {
/* something happened: a failure unless shown otherwise */
        i32_result = -YES;
        if (FD_ISSET(i32_sock, &s_write))
        {
/* writable also after a failure: the socket's error tells */
            if (getsockopt(i32_sock, SOL_SOCKET, SO_ERROR, (char *)&i32_error, &s_len) == 0)
            {
                if (i32_error == 0)
                {
/* it stands */
                    i32_result = YES;
                }
            }
        }
    }
    return i32_result;
}

/* paths */

/* a client's path (from the root if it starts with "/", else from the current folder) as a */
/* clean path from the root, without "." and "..": 0 = ok, below 0 = too long */
static int32_t path_join(const char *pc_cwd, const char *pc_arg, char *pc_out)
{
/* local variables */
    const char *pc_part;
    int32_t i32_len;
/* the path's length, a part's length */
    int32_t i32_part;
    int32_t i32_result;

/* start values */
    pc_part = pc_arg;
    i32_len = 0;
/* no part yet, no error, an empty path */
    i32_part = 0;
    i32_result = 0;
    pc_out[0] = 0;
/* from the current folder ("/" is kept as the empty text while the path is built) */
    if ((pc_arg[0] != '/') && (pc_cwd[YES] != 0))
    {
        strcpy(pc_out, pc_cwd);
        i32_len = (int32_t)strlen(pc_out);
    }
/* part by part */
    while ((*pc_part != 0) && (i32_result == 0))
    {
/* the part's length */
        i32_part = 0;
        while ((pc_part[i32_part] != 0) && (pc_part[i32_part] != '/'))
        {
            i32_part++;
        }
/* nothing between two "/", and "." mean nothing */
        if ((i32_part == 0) || ((i32_part == YES) && (pc_part[0] == '.')))
        {
        }
        else if ((i32_part == (YES + YES)) && (pc_part[0] == '.') && (pc_part[YES] == '.'))
        {
/* "..": the last part goes; the root has no folder above it */
            while ((i32_len != 0) && (pc_out[i32_len - YES] != '/'))
            {
                i32_len--;
            }
/* and the "/" in front of it */
            if (i32_len != 0)
            {
                i32_len--;
            }
/* the path ends there */
            pc_out[i32_len] = 0;
        }
        else if ((i32_len + YES + i32_part) < PATH_BUF)
        {
/* one more part */
            pc_out[i32_len] = '/';
            memcpy(pc_out + i32_len + YES, pc_part, (size_t)i32_part);
/* the path is longer by that */
            i32_len += YES + i32_part;
            pc_out[i32_len] = 0;
        }
        else
        {
/* too long */
            i32_result = -YES;
        }
/* on to the next part */
        pc_part += i32_part;
        if (*pc_part == '/')
        {
            pc_part++;
        }
    }
/* the root itself */
    if (i32_len == 0)
    {
        strcpy(pc_out, "/");
    }
    return i32_result;
}

/* a clean path as the file system's name */
static void path_real(const char *pc_path, char *pc_real)
{
    strcpy(pc_real, g_ac_root);
/* the root folder's own name has no "/" at its end */
    if (pc_path[YES] != 0)
    {
        strcat(pc_real, pc_path);
    }
}

/* what a path is (KIND_*); the file's facts are filled in for KIND_FILE and for folders below the root */
static int32_t path_kind(const char *pc_path, const char *pc_real, struct stat *ps_stat)
{
/* local variables */
    int32_t i32_kind;

/* start values */
    i32_kind = KIND_NONE;
    memset(ps_stat, 0, sizeof *ps_stat);
/* the root is a folder (the card's file system knows no facts about it) */
    if (pc_path[YES] == 0)
    {
        i32_kind = KIND_DIR;
    }
    else if (stat(pc_real, ps_stat) == 0)
    {
/* a file unless it is a folder */
        i32_kind = KIND_FILE;
        if (S_ISDIR(ps_stat->st_mode))
        {
/* a folder */
            i32_kind = KIND_DIR;
        }
    }
    else
    {
/* no such name */
    }
    return i32_kind;
}

/* the last action for the screen: a word and the path's last part */
static void note_last(const char *pc_word, const char *pc_path)
{
/* local variables */
    const char *pc_name;

/* start values */
    pc_name = strrchr(pc_path, '/');
    if (pc_name == NULL)
    {
/* no "/" in it: all of it */
        pc_name = pc_path;
    }
    else
    {
/* after the last "/" */
        pc_name++;
    }
    snprintf(g_ac_last, sizeof g_ac_last, "%s %s", pc_word, pc_name);
}

/* answers and transfers */

/* one answer line to a client; a client that does not take it is dropped */
static void reply(FTP_SES *ps_ses, const char *pc_text)
{
/* local variables */
    char ac_line[REPLY_BUF];
    int32_t i32_len;

/* start values */
    i32_len = snprintf(ac_line, sizeof ac_line, "%s\r\n", pc_text);
    if (i32_len >= (int32_t)sizeof ac_line)
    {
        i32_len = (int32_t)sizeof ac_line - YES;
    }
/* sent, or the client is gone */
    if (sock_send(ps_ses->i32_ctrl, (const uint8_t *)ac_line, (uint32_t)i32_len) != 0)
    {
        ps_ses->i32_quit = YES;
    }
}

/* a transfer's connection, file and folder are closed; the next transfer needs PASV / PORT again */
static void xfer_close(FTP_SES *ps_ses)
{
    sock_close(&ps_ses->i32_data);
    sock_close(&ps_ses->i32_pasv);
/* the file */
    if (ps_ses->i32_fd != NO_FILE)
    {
        (void)close(ps_ses->i32_fd);
        ps_ses->i32_fd = NO_FILE;
    }
/* the folder */
    if (ps_ses->ps_dir != NULL)
    {
        (void)closedir(ps_ses->ps_dir);
        ps_ses->ps_dir = NULL;
    }
/* nothing is under way, nothing waits in the buffer */
    ps_ses->i32_xfer = XFER_NONE;
    ps_ses->i32_mode = DATA_NONE;
/* the buffer */
    ps_ses->i32_pend_at = 0;
    ps_ses->i32_pend_len = 0;
    ps_ses->i32_end = 0;
}

/* a transfer ends: everything closed, then the answer */
static void xfer_finish(FTP_SES *ps_ses, const char *pc_text)
{
    xfer_close(ps_ses);
/* REST counts for one transfer only */
    ps_ses->ui32_rest = 0;
    reply(ps_ses, pc_text);
/* the client's idle time starts now */
    ps_ses->ui32_time = ftp_ms();
    g_i32_work = YES;
}

/* a transfer starts (its file or folder is open): the data connection is asked for */
static void xfer_start(FTP_SES *ps_ses, int32_t i32_kind)
{
/* local variables */
    bool b_ok;

/* start values */
    b_ok = ps_ses->i32_mode != DATA_NONE;
/* the active way: we connect to the client */
    if (ps_ses->i32_mode == DATA_ACTIVE)
    {
        ps_ses->i32_data = sock_connect(ps_ses->i32_ctrl, ps_ses->ui32_port);
        b_ok = ps_ses->i32_data != NO_SOCK;
    }
/* a way to connect is known */
    if (b_ok)
    {
        ps_ses->i32_xfer = i32_kind;
        ps_ses->i32_state = STATE_WAIT;
/* the time for the connection runs from now */
        ps_ses->ui32_time = ftp_ms();
        reply(ps_ses, "150 Opening the data connection");
    }
    else
    {
/* neither PASV nor PORT came, or no socket was free */
        xfer_finish(ps_ses, "425 No data connection (PASV or PORT first)");
    }
}

/* one line of a listing into a buffer: its length */
static int32_t list_line(const FTP_SES *ps_ses, const char *pc_name, char *pc_out)
{
/* local variables */
    char ac_entry[ENTRY_BUF];
    struct stat s_stat;
/* the entry's time, broken down and as it is kept */
    const struct tm *ps_tm;
    time_t s_time;
/* folder or file, the date's parts */
    char c_type;
    int32_t i32_month;
    int32_t i32_day;
/* the year, the line's length */
    int32_t i32_year;
    int32_t i32_len;

/* start values */
    memset(&s_stat, 0, sizeof s_stat);
    c_type = '-';
/* January 1, 1900 where there is no date */
    i32_month = 0;
    i32_day = YES;
    i32_year = TM_YEAR_BASE;
/* the entry's facts */
    snprintf(ac_entry, sizeof ac_entry, "%s/%s", ps_ses->ac_dir, pc_name);
    if (stat(ac_entry, &s_stat) == 0)
    {
        if (S_ISDIR(s_stat.st_mode))
        {
/* a folder */
            c_type = 'd';
        }
/* its date (the card's dates are local time and are given as they are) */
        s_time = s_stat.st_mtime;
        ps_tm = localtime(&s_time);
        if (ps_tm != NULL)
        {
/* the parts the listing shows */
            i32_month = ps_tm->tm_mon;
            i32_day = ps_tm->tm_mday;
            i32_year = ps_tm->tm_year + TM_YEAR_BASE;
        }
    }
/* a month outside the table is not looked up */
    if ((i32_month < 0) || (i32_month >= MONTHS))
    {
        i32_month = 0;
    }
    if (ps_ses->i32_names != 0)
    {
/* names only */
        i32_len = snprintf(pc_out, LIST_LINE_BUF, "%s\r\n", pc_name);
    }
    else
    {
/* as "ls -l" prints it: every client reads that */
        i32_len = snprintf(pc_out, LIST_LINE_BUF, "%crw-rw-rw- 1 ftp ftp %10lu %s %2d  %4d %s\r\n", c_type,
                           (unsigned long)(uint32_t)s_stat.st_size, g_apc_month[i32_month], (int)i32_day,
                           (int)i32_year, pc_name);
    }
/* never more than the line's room */
    if (i32_len >= LIST_LINE_BUF)
    {
        i32_len = LIST_LINE_BUF - YES;
    }
    return i32_len;
}

/* the bytes that wait in a client's buffer go to it, as many as it takes now: 0 = ok, below 0 = */
/* the connection is gone or the client has taken nothing for too long */
static int32_t pend_send(FTP_SES *ps_ses)
{
/* local variables */
    int32_t i32_count;
    int32_t i32_result;

/* start values */
    i32_count = 0;
    i32_result = 0;
    if (ps_ses->i32_pend_len != 0)
    {
/* as much as the client takes */
        i32_count = sock_send_some(ps_ses->i32_data, ps_ses->pui8_buf + ps_ses->i32_pend_at, ps_ses->i32_pend_len);
        if (i32_count > 0)
        {
/* some went */
            ps_ses->i32_pend_at += i32_count;
            ps_ses->i32_pend_len -= i32_count;
/* the client is alive */
            ps_ses->ui32_time = ftp_ms();
            g_i32_work = YES;
        }
        else if ((i32_count < 0) || ((ftp_ms() - ps_ses->ui32_time) > STALL_MS))
        {
/* gone, or stuck */
            i32_result = -YES;
        }
        else
        {
/* no room now: next time */
        }
    }
    return i32_result;
}

/* a listing: the next lines */
static void list_step(FTP_SES *ps_ses)
{
/* local variables */
    const struct dirent *ps_entry;
    int32_t i32_len;

/* start values */
    ps_entry = NULL;
    i32_len = 0;
/* the buffer is empty: as many entries as it takes */
    if ((ps_ses->i32_pend_len == 0) && (ps_ses->i32_end == 0))
    {
        while ((ps_ses->i32_end == 0) && (i32_len < (XFER_BUF_SIZE - LIST_LINE_BUF)))
        {
/* the next entry, or the folder's end */
            ps_entry = readdir(ps_ses->ps_dir);
            if (ps_entry == NULL)
            {
                ps_ses->i32_end = YES;
            }
/* the folder itself and the one above are not listed */
            else if ((strcmp(ps_entry->d_name, ".") != 0) && (strcmp(ps_entry->d_name, "..") != 0))
            {
                i32_len += list_line(ps_ses, ps_entry->d_name, (char *)ps_ses->pui8_buf + i32_len);
            }
            else
            {
/* "." or ".." */
            }
        }
        ps_ses->i32_pend_at = 0;
        ps_ses->i32_pend_len = i32_len;
        g_i32_work = YES;
    }
/* to the client */
    if (pend_send(ps_ses) != 0)
    {
        xfer_finish(ps_ses, "426 Data connection lost");
    }
    else if ((ps_ses->i32_pend_len == 0) && (ps_ses->i32_end != 0))
    {
/* all of it */
        xfer_finish(ps_ses, "226 Listing complete");
    }
    else
    {
/* more next time */
    }
}

/* a file to the client: the next piece */
static void retr_step(FTP_SES *ps_ses)
{
/* local variables */
    int32_t i32_count;

/* start values */
    i32_count = 0;
/* the buffer is empty: the file's next piece */
    if ((ps_ses->i32_pend_len == 0) && (ps_ses->i32_end == 0))
    {
        i32_count = (int32_t)read(ps_ses->i32_fd, ps_ses->pui8_buf, XFER_BUF_SIZE);
        if (i32_count > 0)
        {
/* a piece to send */
            ps_ses->i32_pend_at = 0;
            ps_ses->i32_pend_len = i32_count;
/* counted for the screen */
            g_ui64_bytes_out += (uint32_t)i32_count;
        }
        else
        {
/* the file's end, or a read error */
            ps_ses->i32_end = YES;
        }
        g_i32_work = YES;
    }
/* a read error ends the transfer */
    if (i32_count < 0)
    {
        xfer_finish(ps_ses, "451 Card read error");
    }
/* the buffer's bytes go to the client */
    else if (pend_send(ps_ses) != 0)
    {
        xfer_finish(ps_ses, "426 Data connection lost");
    }
    else if ((ps_ses->i32_pend_len == 0) && (ps_ses->i32_end != 0))
    {
/* all of it */
        g_ui32_files_out++;
        xfer_finish(ps_ses, "226 Transfer complete");
    }
    else
    {
/* more next time */
    }
}

/* a file from the client: what has arrived goes to the card; the connection's end is the file's end */
static void stor_step(FTP_SES *ps_ses)
{
/* local variables */
    int32_t i32_count;
    int32_t i32_got;
/* more may wait, the client closed the connection */
    bool b_more;
    bool b_closed;

/* start values */
    i32_count = 0;
    i32_got = 0;
/* go on, the connection stands */
    b_more = true;
    b_closed = false;
/* all that waits, up to a full buffer */
    while (b_more && (i32_count < XFER_BUF_SIZE))
    {
        i32_got = sock_recv(ps_ses->i32_data, ps_ses->pui8_buf + i32_count, XFER_BUF_SIZE - i32_count);
        if (i32_got > 0)
        {
/* into the buffer after the others */
            i32_count += i32_got;
        }
        else
        {
/* nothing more now, or never */
            b_more = false;
            b_closed = i32_got < 0;
        }
    }
/* to the card */
    if ((i32_count != 0) && ((int32_t)write(ps_ses->i32_fd, ps_ses->pui8_buf, (size_t)i32_count) != i32_count))
    {
/* the card took less than all */
        xfer_finish(ps_ses, "452 Card write error (card full?)");
    }
    else
    {
        if (i32_count != 0)
        {
/* written */
            g_ui64_bytes_in += (uint32_t)i32_count;
            ps_ses->ui32_time = ftp_ms();
            g_i32_work = YES;
        }
/* the connection's end is the file's end */
        if (b_closed)
        {
            g_ui32_files_in++;
            xfer_finish(ps_ses, "226 Transfer complete");
        }
/* a client that sends nothing and does not close */
        else if ((ftp_ms() - ps_ses->ui32_time) > STALL_MS)
        {
            xfer_finish(ps_ses, "426 No data for too long");
        }
        else
        {
/* more next time */
        }
    }
}

/* a transfer: wait for its data connection, then move a piece */
static void xfer_step(FTP_SES *ps_ses)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = 0;
    if (ps_ses->i32_state == STATE_WAIT)
    {
        if (ps_ses->i32_mode == DATA_PASSIVE)
        {
/* the client connects to our port; the port is closed once it has */
            ps_ses->i32_data = sock_accept(ps_ses->i32_pasv);
            if (ps_ses->i32_data != NO_SOCK)
            {
/* the data connection stands */
                sock_close(&ps_ses->i32_pasv);
                i32_result = YES;
            }
        }
        else
        {
/* our connection to the client */
            i32_result = sock_connected(ps_ses->i32_data);
        }
        if (i32_result > 0)
        {
/* data moves from now on; the stall time starts */
            ps_ses->i32_state = STATE_RUN;
            ps_ses->ui32_time = ftp_ms();
            g_i32_work = YES;
        }
/* refused, or not made in time */
        else if ((i32_result < 0) || ((ftp_ms() - ps_ses->ui32_time) > DATA_WAIT_MS))
        {
            xfer_finish(ps_ses, "425 No data connection");
        }
        else
        {
/* not yet */
        }
    }
    else if (ps_ses->i32_xfer == XFER_LIST)
    {
        list_step(ps_ses);
    }
/* a file to the client */
    else if (ps_ses->i32_xfer == XFER_RETR)
    {
        retr_step(ps_ses);
    }
    else
    {
/* a file from the client */
        stor_step(ps_ses);
    }
}

/* commands */

/* a command's path as a clean path and as the file system's name: 0 = ok; a path that is too */
/* long is answered here */
static int32_t resolve(FTP_SES *ps_ses, const char *pc_arg, char *pc_path, char *pc_real)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = path_join(ps_ses->ac_cwd, pc_arg, pc_path);
    if (i32_result == 0)
    {
/* below the root folder */
        path_real(pc_path, pc_real);
    }
    else
    {
/* nothing can be done with it */
        reply(ps_ses, "550 Path too long");
    }
    return i32_result;
}

/* CWD, CDUP: another current folder */
static void cmd_cwd(FTP_SES *ps_ses, const char *pc_arg)
{
/* local variables */
    char ac_path[PATH_BUF];
    char ac_real[REAL_BUF];
    struct stat s_stat;

/* the path must be a folder */
    if (resolve(ps_ses, pc_arg, ac_path, ac_real) == 0)
    {
        if (path_kind(ac_path, ac_real, &s_stat) == KIND_DIR)
        {
/* it is the current folder from now on */
            strcpy(ps_ses->ac_cwd, ac_path);
            reply(ps_ses, "250 Folder changed");
        }
        else
        {
/* a file, or nothing */
            reply(ps_ses, "550 No such folder");
        }
    }
}

/* PWD: the current folder (a quote in its name is doubled) */
static void cmd_pwd(FTP_SES *ps_ses)
{
/* local variables */
    char ac_text[REPLY_BUF];
    const char *pc_from;
    int32_t i32_len;

/* start values */
    pc_from = ps_ses->ac_cwd;
    i32_len = snprintf(ac_text, sizeof ac_text, "257 \"");
/* at most twice the path's length: the buffer holds that */
    while (*pc_from != 0)
    {
        if (*pc_from == '"')
        {
/* a second quote in front of it */
            ac_text[i32_len] = '"';
            i32_len++;
        }
/* the character itself */
        ac_text[i32_len] = *pc_from;
        i32_len++;
        pc_from++;
    }
/* the closing quote and the text */
    strcpy(ac_text + i32_len, "\" is the current folder");
    reply(ps_ses, ac_text);
}

/* PASV, EPSV: we listen on a port for the next transfer's data connection */
static void cmd_pasv(FTP_SES *ps_ses, int32_t i32_extended)
{
/* local variables */
    char ac_text[REPLY_BUF];
    struct sockaddr_in s_where;
    socklen_t s_len;
/* our address byte by byte, the port we got */
    const uint8_t *pui8_ip;
    uint32_t ui32_port;

/* start values */
    memset(&s_where, 0, sizeof s_where);
    s_len = (socklen_t)sizeof s_where;
/* the address's bytes are in s_where */
    pui8_ip = (const uint8_t *)&s_where.sin_addr.s_addr;
    ui32_port = 0;
/* an earlier port that was not used is closed */
    xfer_close(ps_ses);
    ps_ses->i32_pasv = sock_listen(0, &ui32_port);
    if (ps_ses->i32_pasv == NO_SOCK)
    {
/* no socket was free */
        reply(ps_ses, "425 No port free");
    }
    else
    {
        ps_ses->i32_mode = DATA_PASSIVE;
/* EPSV gives the port alone */
        if (i32_extended != 0)
        {
            snprintf(ac_text, sizeof ac_text, "229 Entering Extended Passive Mode (|||%u|)", (unsigned)ui32_port);
        }
        else
        {
/* our address is the one the client reached us at */
            (void)getsockname(ps_ses->i32_ctrl, (struct sockaddr *)&s_where, &s_len);
            snprintf(ac_text, sizeof ac_text, "227 Entering Passive Mode (%u,%u,%u,%u,%u,%u)", (unsigned)pui8_ip[0],
                     (unsigned)pui8_ip[IP_BYTE_1], (unsigned)pui8_ip[IP_BYTE_2], (unsigned)pui8_ip[IP_BYTE_3],
                     (unsigned)(ui32_port >> PORT_SHIFT), (unsigned)(ui32_port & PORT_BYTE_MASK));
        }
        reply(ps_ses, ac_text);
    }
}

/* PORT: the next transfer's data connection goes to the client's port */
static void cmd_port(FTP_SES *ps_ses, const char *pc_arg)
{
/* local variables */
    unsigned int aui_field[PORT_FIELDS];
    int32_t i32_count;

/* start values */
    i32_count = sscanf(pc_arg, "%u,%u,%u,%u,%u,%u", &aui_field[0], &aui_field[IP_BYTE_1], &aui_field[IP_BYTE_2],
                       &aui_field[IP_BYTE_3], &aui_field[PORT_HIGH], &aui_field[PORT_LOW]);
    xfer_close(ps_ses);
/* the address given is not used: the connection goes to where the commands come from */
    if ((i32_count == PORT_FIELDS) && (aui_field[PORT_HIGH] <= PORT_BYTE_MASK) && (aui_field[PORT_LOW] <= PORT_BYTE_MASK))
    {
        ps_ses->ui32_port = ((uint32_t)aui_field[PORT_HIGH] << PORT_SHIFT) | (uint32_t)aui_field[PORT_LOW];
/* the active way from now on */
        ps_ses->i32_mode = DATA_ACTIVE;
        reply(ps_ses, "200 PORT taken");
    }
    else
    {
/* not six numbers, or a port byte above 255 */
        reply(ps_ses, "501 Bad PORT");
    }
}

/* LIST, NLST: a folder's entries (options such as "-la" are passed over) */
static void cmd_list(FTP_SES *ps_ses, const char *pc_arg, int32_t i32_names)
{
/* local variables */
    char ac_path[PATH_BUF];

/* the options */
    while (*pc_arg == '-')
    {
        while ((*pc_arg != 0) && (*pc_arg != ' '))
        {
            pc_arg++;
        }
/* the spaces after one */
        while (*pc_arg == ' ')
        {
            pc_arg++;
        }
    }
/* the folder */
    if (resolve(ps_ses, pc_arg, ac_path, ps_ses->ac_dir) == 0)
    {
        ps_ses->ps_dir = opendir(ps_ses->ac_dir);
        if (ps_ses->ps_dir == NULL)
        {
/* not a folder, or not there */
            reply(ps_ses, "550 No such folder");
        }
        else
        {
/* the lines go over the data connection */
            ps_ses->i32_names = i32_names;
            xfer_start(ps_ses, XFER_LIST);
        }
    }
}

/* RETR: a file to the client, from REST's position on */
static void cmd_retr(FTP_SES *ps_ses, const char *pc_arg)
{
/* local variables */
    char ac_path[PATH_BUF];
    char ac_real[REAL_BUF];
    struct stat s_stat;

/* only a file can be sent */
    if (resolve(ps_ses, pc_arg, ac_path, ac_real) == 0)
    {
        if (path_kind(ac_path, ac_real, &s_stat) == KIND_FILE)
        {
            ps_ses->i32_fd = open(ac_real, O_RDONLY | OPEN_BINARY);
        }
/* not a file, or it cannot be opened */
        if (ps_ses->i32_fd < 0)
        {
/* no file is open */
            ps_ses->i32_fd = NO_FILE;
            reply(ps_ses, "550 No such file");
        }
        else
        {
/* on from REST's position */
            if (ps_ses->ui32_rest != 0)
            {
                (void)lseek(ps_ses->i32_fd, (off_t)ps_ses->ui32_rest, SEEK_SET);
            }
/* for the screen, then the transfer */
            note_last("Sent", ac_path);
            xfer_start(ps_ses, XFER_RETR);
        }
    }
}

/* STOR, APPE: a file from the client. A file of that name is replaced (STOR), continued at */
/* REST's position (STOR after REST) or at its end (APPE) */
static void cmd_stor(FTP_SES *ps_ses, const char *pc_arg, int32_t i32_append)
{
/* local variables */
    char ac_path[PATH_BUF];
    char ac_real[REAL_BUF];
    struct stat s_stat;
/* how the file is opened */
    int32_t i32_flags;

/* start values */
    i32_flags = O_WRONLY | O_CREAT | OPEN_BINARY;
    if (i32_append != 0)
    {
        i32_flags |= O_APPEND;
    }
/* a new file from its start: the old one's contents go */
    else if (ps_ses->ui32_rest == 0)
    {
        i32_flags |= O_TRUNC;
    }
    else
    {
/* continued: the contents stay */
    }
    if (resolve(ps_ses, pc_arg, ac_path, ac_real) == 0)
    {
        if (path_kind(ac_path, ac_real, &s_stat) != KIND_DIR)
        {
            ps_ses->i32_fd = open(ac_real, i32_flags, FILE_MODE);
        }
/* a folder of that name, no such folder, a name the card cannot hold, a full card */
        if (ps_ses->i32_fd < 0)
        {
/* no file is open */
            ps_ses->i32_fd = NO_FILE;
            reply(ps_ses, "550 The file cannot be created");
        }
        else
        {
/* on from REST's position */
            if ((i32_append == 0) && (ps_ses->ui32_rest != 0))
            {
                (void)lseek(ps_ses->i32_fd, (off_t)ps_ses->ui32_rest, SEEK_SET);
            }
/* for the screen, then the transfer */
            note_last("Received", ac_path);
            xfer_start(ps_ses, XFER_STOR);
        }
    }
}

/* DELE, RMD, MKD: a file goes, an empty folder goes, a new folder */
static void cmd_change(FTP_SES *ps_ses, int32_t i32_cmd, const char *pc_arg)
{
/* local variables */
    char ac_path[PATH_BUF];
    char ac_real[REAL_BUF];
    char ac_text[REPLY_BUF];
/* 0 = the file system did it */
    int32_t i32_result;

/* start values */
    i32_result = -YES;
    if (resolve(ps_ses, pc_arg, ac_path, ac_real) == 0)
    {
/* never the root itself */
        if (ac_path[YES] == 0)
        {
        }
        else if (i32_cmd == CMD_DELE)
        {
            i32_result = unlink(ac_real);
        }
/* an empty folder goes */
        else if ((i32_cmd == CMD_RMD) || (i32_cmd == CMD_XRMD))
        {
            i32_result = rmdir(ac_real);
        }
        else
        {
/* a new folder */
            i32_result = MAKE_DIR(ac_real);
        }
/* the answer */
        if (i32_result != 0)
        {
            reply(ps_ses, "550 That did not work");
        }
        else if ((i32_cmd == CMD_MKD) || (i32_cmd == CMD_XMKD))
        {
/* the new folder's name goes back */
            note_last("New folder", ac_path);
/* in quotes, as the clients expect it */
            snprintf(ac_text, sizeof ac_text, "257 \"%s\" created", ac_path);
            reply(ps_ses, ac_text);
        }
        else
        {
/* a file or a folder went */
            note_last("Deleted", ac_path);
            reply(ps_ses, "250 Deleted");
        }
    }
}

/* RNFR, RNTO: another name, or another folder */
static void cmd_rename(FTP_SES *ps_ses, int32_t i32_cmd, const char *pc_arg)
{
/* local variables */
    char ac_path[PATH_BUF];
    char ac_real[REAL_BUF];
    char ac_from[REAL_BUF];
/* the old name's facts (not used) */
    struct stat s_stat;

    if (resolve(ps_ses, pc_arg, ac_path, ac_real) == 0)
    {
        if (i32_cmd == CMD_RNFR)
        {
/* the old name must be there, and is kept for RNTO */
            ps_ses->ac_from[0] = 0;
            if ((ac_path[YES] != 0) && (path_kind(ac_path, ac_real, &s_stat) != KIND_NONE))
            {
/* remembered as a clean path */
                strcpy(ps_ses->ac_from, ac_path);
                reply(ps_ses, "350 Now the new name (RNTO)");
            }
            else
            {
/* the root, or no such name */
                reply(ps_ses, "550 No such file");
            }
        }
/* RNTO without an old name */
        else if (ps_ses->ac_from[0] == 0)
        {
            reply(ps_ses, "503 RNFR first");
        }
        else
        {
/* the old name is used up either way */
            path_real(ps_ses->ac_from, ac_from);
            ps_ses->ac_from[0] = 0;
            if (rename(ac_from, ac_real) == 0)
            {
/* for the screen */
                note_last("Renamed", ac_path);
                reply(ps_ses, "250 Renamed");
            }
            else
            {
/* the file system refused it */
                reply(ps_ses, "550 That did not work");
            }
        }
    }
}

/* SIZE, MDTM: a file's length, its date */
static void cmd_facts(FTP_SES *ps_ses, int32_t i32_cmd, const char *pc_arg)
{
/* local variables */
    char ac_path[PATH_BUF];
    char ac_real[REAL_BUF];
    char ac_text[REPLY_BUF];
/* the file's facts */
    struct stat s_stat;
/* the date */
    const struct tm *ps_tm;
    time_t s_time;

/* start values */
    ps_tm = NULL;
    if (resolve(ps_ses, pc_arg, ac_path, ac_real) == 0)
    {
/* only files have them */
        if (path_kind(ac_path, ac_real, &s_stat) != KIND_FILE)
        {
            reply(ps_ses, "550 No such file");
        }
        else if (i32_cmd == CMD_SIZE)
        {
/* the length in bytes */
            snprintf(ac_text, sizeof ac_text, "213 %lu", (unsigned long)(uint32_t)s_stat.st_size);
            reply(ps_ses, ac_text);
        }
        else
        {
/* the date as 14 digits */
            s_time = s_stat.st_mtime;
            ps_tm = localtime(&s_time);
            if (ps_tm == NULL)
            {
/* a time the library cannot break down */
                reply(ps_ses, "550 No date");
            }
            else
            {
/* year, month, day, hour, minute, second */
                snprintf(ac_text, sizeof ac_text, "213 %04d%02d%02d%02d%02d%02d", ps_tm->tm_year + TM_YEAR_BASE,
                         ps_tm->tm_mon + TM_MONTH_BASE, ps_tm->tm_mday, ps_tm->tm_hour, ps_tm->tm_min, ps_tm->tm_sec);
                reply(ps_ses, ac_text);
            }
        }
    }
}

/* which command a line starts with (CMD_COUNT: none we know); *ppc_arg = what follows it */
static int32_t parse(char *pc_line, const char **ppc_arg)
{
/* local variables */
    char ac_verb[VERB_BUF];
    int32_t i32_len;
    int32_t i32_cmd;

/* start values */
    i32_len = 0;
    i32_cmd = 0;
/* the name in capitals, up to the first space */
    while ((i32_len < VERB_MAX) && (pc_line[i32_len] != 0) && (pc_line[i32_len] != ' '))
    {
        ac_verb[i32_len] = pc_line[i32_len];
        if ((ac_verb[i32_len] >= 'a') && (ac_verb[i32_len] <= 'z'))
        {
/* a small letter as its capital */
            ac_verb[i32_len] = (char)((ac_verb[i32_len] - 'a') + 'A');
        }
        i32_len++;
    }
    ac_verb[i32_len] = 0;
/* a longer name is none of ours */
    if ((pc_line[i32_len] != 0) && (pc_line[i32_len] != ' '))
    {
        ac_verb[0] = 0;
    }
/* its place in the table */
    while ((i32_cmd < CMD_COUNT) && (strcmp(ac_verb, g_apc_verb[i32_cmd]) != 0))
    {
        i32_cmd++;
    }
/* the argument, after the spaces */
    while (pc_line[i32_len] == ' ')
    {
        i32_len++;
    }
/* the argument starts here */
    *ppc_arg = pc_line + i32_len;
    return i32_cmd;
}

/* a client's command line */
static void command(FTP_SES *ps_ses)
{
/* local variables */
    const char *pc_arg;
    int32_t i32_cmd;

/* start values */
    pc_arg = NULL;
    i32_cmd = parse(ps_ses->ac_line, &pc_arg);
    ps_ses->ui32_time = ftp_ms();
/* RNTO must follow RNFR at once */
    if ((i32_cmd != CMD_RNTO) && (i32_cmd != CMD_RNFR))
    {
        ps_ses->ac_from[0] = 0;
    }
    if ((i32_cmd >= CMD_RETR) && (i32_cmd <= CMD_MDTM) && (pc_arg[0] == 0))
    {
/* a name is needed and none came */
        reply(ps_ses, "501 A name is missing");
    }
    else
    {
        switch (i32_cmd)
        {
/* anybody may come in, with any password or none */
            case CMD_USER:
                reply(ps_ses, "331 Any password will do");
                break;
/* the password is not looked at */
            case CMD_PASS:
                reply(ps_ses, "230 Welcome");
                break;
/* what we are */
            case CMD_SYST:
                reply(ps_ses, "215 UNIX Type: L8");
                break;
/* what we can do beyond the basic commands */
            case CMD_FEAT:
                reply(ps_ses, "211-Features:\r\n SIZE\r\n MDTM\r\n REST STREAM\r\n PASV\r\n EPSV\r\n UTF8\r\n211 End");
                break;
/* folders */
            case CMD_PWD:
            case CMD_XPWD:
/* the current one's name */
                cmd_pwd(ps_ses);
                break;
/* another current folder */
            case CMD_CWD:
            case CMD_XCWD:
/* from the root or from the current one */
                cmd_cwd(ps_ses, pc_arg);
                break;
/* one folder up */
            case CMD_CDUP:
            case CMD_XCUP:
/* the same command with ".." */
                cmd_cwd(ps_ses, "..");
                break;
/* settings that change nothing here: all transfers are binary streams */
            case CMD_TYPE:
            case CMD_MODE:
            case CMD_STRU:
/* commands that need no action */
            case CMD_NOOP:
            case CMD_OPTS:
            case CMD_ALLO:
/* all are answered the same way */
                reply(ps_ses, "200 OK");
                break;
/* the data connection */
            case CMD_PASV:
                cmd_pasv(ps_ses, 0);
                break;
/* the same with the extended answer */
            case CMD_EPSV:
                cmd_pasv(ps_ses, YES);
                break;
/* the active way */
            case CMD_PORT:
                cmd_port(ps_ses, pc_arg);
                break;
/* where the next file transfer starts */
            case CMD_REST:
                ps_ses->ui32_rest = (uint32_t)strtoul(pc_arg, NULL, 0);
/* RETR or STOR is expected next */
                reply(ps_ses, "350 Position taken");
                break;
/* listings */
            case CMD_LIST:
                cmd_list(ps_ses, pc_arg, 0);
                break;
/* names only */
            case CMD_NLST:
                cmd_list(ps_ses, pc_arg, YES);
                break;
/* files */
            case CMD_RETR:
                cmd_retr(ps_ses, pc_arg);
                break;
/* a new or replaced file */
            case CMD_STOR:
                cmd_stor(ps_ses, pc_arg, 0);
                break;
/* more for a file's end */
            case CMD_APPE:
                cmd_stor(ps_ses, pc_arg, YES);
                break;
/* deleting, new folders */
            case CMD_DELE:
            case CMD_MKD:
            case CMD_XMKD:
/* both names of RMD */
            case CMD_RMD:
            case CMD_XRMD:
/* one function does the three */
                cmd_change(ps_ses, i32_cmd, pc_arg);
                break;
/* names */
            case CMD_RNFR:
            case CMD_RNTO:
/* the old name first, then the new one */
                cmd_rename(ps_ses, i32_cmd, pc_arg);
                break;
/* a file's facts */
            case CMD_SIZE:
            case CMD_MDTM:
/* length or date */
                cmd_facts(ps_ses, i32_cmd, pc_arg);
                break;
/* nothing is under way when a command gets here */
            case CMD_ABOR:
                xfer_close(ps_ses);
/* that is no error */
                reply(ps_ses, "226 Nothing to stop");
                break;
/* the server's state */
            case CMD_STAT:
                reply(ps_ses, "211 L: SD card, running");
                break;
/* the client leaves */
            case CMD_QUIT:
                reply(ps_ses, "221 Bye");
/* dropped after the answer */
                ps_ses->i32_quit = YES;
                break;
/* any other command */
            default:
                reply(ps_ses, "502 Not known here");
                break;
        }
    }
}

/* clients */

/* a client's command bytes into its line, until a whole line waits; a closed connection ends the client */
static void ctrl_read(FTP_SES *ps_ses)
{
/* local variables */
    uint8_t ui8_byte;
    int32_t i32_got;

/* start values */
    ui8_byte = 0;
    i32_got = YES;
    while ((ps_ses->i32_ready == 0) && (i32_got > 0))
    {
/* byte by byte */
        i32_got = sock_recv(ps_ses->i32_ctrl, &ui8_byte, YES);
        if (i32_got < 0)
        {
/* the connection is closed */
            ps_ses->i32_quit = YES;
        }
        else if (i32_got == 0)
        {
/* nothing more now */
        }
        else if (ps_ses->i32_iac != 0)
        {
/* the byte after telnet's marker */
            ps_ses->i32_iac = 0;
        }
        else if (ui8_byte == TELNET_IAC)
        {
/* telnet's marker: the next byte is not ours */
            ps_ses->i32_iac = YES;
        }
        else if (ui8_byte == '\n')
        {
/* the line's end */
            ps_ses->ac_line[ps_ses->i32_len] = 0;
            ps_ses->i32_ready = YES;
        }
        else if ((ui8_byte != '\r') && (ps_ses->i32_len < (LINE_BUF - YES)))
        {
/* one more character */
            ps_ses->ac_line[ps_ses->i32_len] = (char)ui8_byte;
            ps_ses->i32_len++;
        }
        else
        {
/* a carriage return, or more than a line holds */
        }
    }
}

/* a client is dropped: its transfer, its connection */
static void ses_close(FTP_SES *ps_ses)
{
    xfer_close(ps_ses);
    sock_close(&ps_ses->i32_ctrl);
/* the place is free */
    ps_ses->i32_used = 0;
}

/* a new client on a control connection; with all places taken it is sent away */
static void ses_open(int32_t i32_sock)
{
/* local variables */
    FTP_SES *ps_ses;
    int32_t i32_index;
    int32_t i32_on;

/* start values */
    ps_ses = NULL;
    i32_index = 0;
    i32_on = YES;
/* a free place */
    for (i32_index = 0; i32_index < FTP_SESSIONS; i32_index++)
    {
        if ((ps_ses == NULL) && (g_ps_ses[i32_index].i32_used == 0))
        {
            ps_ses = &g_ps_ses[i32_index];
        }
    }
/* all places are taken */
    if (ps_ses == NULL)
    {
        (void)sock_send(i32_sock, (const uint8_t *)"421 Too many clients, try later\r\n",
                        (uint32_t)strlen("421 Too many clients, try later\r\n"));
/* that connection is not kept */
        sock_close(&i32_sock);
    }
    else
    {
#ifdef SO_OOBINLINE
/* clients send ABOR as urgent data: it is read in its place among the other bytes */
        (void)setsockopt(i32_sock, SOL_SOCKET, SO_OOBINLINE, (const char *)&i32_on, (socklen_t)sizeof i32_on);
#endif
/* as new: in the root folder, nothing under way */
        memset(ps_ses, 0, sizeof *ps_ses);
        ps_ses->i32_used = YES;
        ps_ses->i32_ctrl = i32_sock;
/* no other sockets, no file */
        ps_ses->i32_data = NO_SOCK;
        ps_ses->i32_pasv = NO_SOCK;
        ps_ses->i32_fd = NO_FILE;
/* its buffer, its folder, its clock */
        ps_ses->pui8_buf = g_pui8_buf + ((ps_ses - g_ps_ses) * XFER_BUF_SIZE);
        strcpy(ps_ses->ac_cwd, "/");
        ps_ses->ui32_time = ftp_ms();
/* the greeting */
        reply(ps_ses, "220 L: SD card (no password needed)");
    }
}

/* a client's turn */
static void ses_step(FTP_SES *ps_ses)
{
/* local variables */
    const char *pc_arg;

/* start values */
    pc_arg = NULL;
    ctrl_read(ps_ses);
    if (ps_ses->i32_xfer != XFER_NONE)
    {
/* during a transfer only ABOR is taken; any other command waits for the transfer's end */
        if ((ps_ses->i32_ready != 0) && (parse(ps_ses->ac_line, &pc_arg) == CMD_ABOR))
        {
            xfer_finish(ps_ses, "426 Transfer stopped");
            reply(ps_ses, "226 Stopped");
/* the line is used up */
            ps_ses->i32_len = 0;
            ps_ses->i32_ready = 0;
        }
        else if (ps_ses->i32_quit == 0)
        {
/* the transfer's next piece */
            xfer_step(ps_ses);
        }
        else
        {
/* the client is gone: closed below */
        }
    }
    else if (ps_ses->i32_ready != 0)
    {
        g_i32_work = YES;
        command(ps_ses);
/* the line is used up */
        ps_ses->i32_len = 0;
        ps_ses->i32_ready = 0;
    }
    else if ((ftp_ms() - ps_ses->ui32_time) > IDLE_MS)
    {
/* silent for too long */
        reply(ps_ses, "421 Idle for too long");
        ps_ses->i32_quit = YES;
    }
    else
    {
/* nothing to do */
    }
    if (ps_ses->i32_quit != 0)
    {
        ses_close(ps_ses);
    }
}

/* ftp.h */

/* start the server: 0 = ok */
int32_t ftp_start(const char *pc_root, uint32_t ui32_port)
{
/* local variables */
    uint32_t ui32_bound;
    int32_t i32_result;

/* start values */
    ui32_bound = 0;
    i32_result = -YES;
    ftp_stop();
/* the counters start again */
    g_ui32_files_in = 0;
    g_ui32_files_out = 0;
/* the bytes, the last action */
    g_ui64_bytes_in = 0;
    g_ui64_bytes_out = 0;
    g_ac_last[0] = 0;
/* the root folder's name, the memory, the port */
    if (strlen(pc_root) < ROOT_BUF)
    {
        strcpy(g_ac_root, pc_root);
/* the clients (cleared), their buffers */
        g_ps_ses = (FTP_SES *)calloc(FTP_SESSIONS, sizeof(FTP_SES));
        g_pui8_buf = (uint8_t *)malloc(FTP_SESSIONS * XFER_BUF_SIZE);
        if ((g_ps_ses != NULL) && (g_pui8_buf != NULL))
        {
/* the control port */
            g_i32_listen = sock_listen(ui32_port, &ui32_bound);
        }
    }
/* everything is there */
    if (g_i32_listen != NO_SOCK)
    {
        i32_result = 0;
    }
    else
    {
/* nothing stays half made */
        ftp_stop();
    }
    return i32_result;
}

/* stop it: all connections and files are closed */
void ftp_stop(void)
{
/* local variables */
    int32_t i32_index;

/* start values */
    i32_index = 0;
    if (g_ps_ses != NULL)
    {
/* every client goes */
        for (i32_index = 0; i32_index < FTP_SESSIONS; i32_index++)
        {
            if (g_ps_ses[i32_index].i32_used != 0)
            {
                ses_close(&g_ps_ses[i32_index]);
            }
        }
    }
/* the port, the memory */
    sock_close(&g_i32_listen);
    free(g_ps_ses);
    free(g_pui8_buf);
/* nothing is allocated now */
    g_ps_ses = NULL;
    g_pui8_buf = NULL;
}

/* often: new clients, commands, a piece of every transfer; 1 = there was work */
int32_t ftp_poll(void)
{
/* local variables */
    int32_t i32_sock;
    int32_t i32_index;
    int32_t i32_busy;

/* start values */
    i32_sock = NO_SOCK;
    i32_index = 0;
    g_i32_work = 0;
/* only while the server runs */
    if (g_i32_listen != NO_SOCK)
    {
/* new clients */
        do
        {
            i32_sock = sock_accept(g_i32_listen);
            if (i32_sock != NO_SOCK)
            {
/* a place for it */
                ses_open(i32_sock);
                g_i32_work = YES;
            }
        } while (i32_sock != NO_SOCK);
/* every client's turn */
        for (i32_index = 0; i32_index < FTP_SESSIONS; i32_index++)
        {
            if (g_ps_ses[i32_index].i32_used != 0)
            {
                ses_step(&g_ps_ses[i32_index]);
            }
        }
    }
/* 1 = call again soon */
    i32_busy = g_i32_work;
    return i32_busy;
}

/* what it did so far */
void ftp_info(FTP_INFO *ps_info)
{
/* local variables */
    int32_t i32_index;

/* start values */
    i32_index = 0;
    memset(ps_info, 0, sizeof *ps_info);
    if (g_ps_ses != NULL)
    {
/* the clients connected now */
        for (i32_index = 0; i32_index < FTP_SESSIONS; i32_index++)
        {
            if (g_ps_ses[i32_index].i32_used != 0)
            {
                ps_info->i32_clients++;
            }
        }
    }
/* files and kilobytes */
    ps_info->ui32_files_in = g_ui32_files_in;
    ps_info->ui32_files_out = g_ui32_files_out;
/* bytes as kilobytes */
    ps_info->ui32_kb_in = (uint32_t)(g_ui64_bytes_in >> KB_SHIFT);
    ps_info->ui32_kb_out = (uint32_t)(g_ui64_bytes_out >> KB_SHIFT);
    strcpy(ps_info->ac_last, g_ac_last);
}
