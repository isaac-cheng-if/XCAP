/* xil_printf output: the UART (nothing listens on this card) and an 8 KB ring in memory that xsdb can read
 * (LogRing, LogPos: write position, counts up). Replaces the BSP's blocking outbyte(). */
#include "xparameters.h"
#include "xil_io.h"

#define UART_TX   (STDOUT_BASEADDRESS + 0x4u)
#define UART_STAT (STDOUT_BASEADDRESS + 0x8u)

char LogRing[8192];
volatile unsigned LogPos;

void outbyte(char c)
{
    LogRing[LogPos & 8191u] = c;
    LogPos++;
    if (!(Xil_In32(UART_STAT) & 0x8u)) Xil_Out32(UART_TX, (u8)c);   /* FIFO full: drop instead of waiting */
}
