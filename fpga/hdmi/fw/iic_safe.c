/* I2C on the card's control bus (TMDS181, DP159, IDT 8T49N241) with timeouts.
 * The BSP's polled XIic_Send / XIic_Recv wait without limit for the bus to become busy after a START. On this card that
 * wait never ended twice: once after a controller reset during the previous STOP, once right after the clock chip left
 * reset. These versions use the AXI IIC dynamic mode (START / STOP flags written with the bytes), give up after
 * 20 ms, reset the controller and try again. A write that ends in a repeated START is kept and sent together with the
 * following read, so register reads are one transfer on the wire, as before. */
#include "xparameters.h"
#include "xil_io.h"
#include "sleep.h"
#include "iic_safe.h"

#define R_ISR     0x020u
#define R_RESET   0x040u
#define R_CR      0x100u
#define R_SR      0x104u
#define R_TX      0x108u
#define R_RX      0x10Cu
#define R_RXPIRQ  0x120u
#define DYN_START 0x100u
#define DYN_STOP  0x200u
#define SR_BB     0x04u
#define SR_TXFULL 0x10u
#define SR_RXEMP  0x40u
#define SR_TXEMP  0x80u
#define ISR_ARB   0x01u                 /* arbitration lost */
#define ISR_TXERR 0x02u                 /* no acknowledge */
#define TRIES     3
#define LIMIT_US  20000u

static u8 Pend[4];
static unsigned PendN;
static u8 PendAddr = 0xFF;
u32 IicErrors;                          /* failed attempts, for the log */

static void Prep(UINTPTR b)
{
    Xil_Out32(b + R_RESET, 0xAu);
    usleep(5);
    Xil_Out32(b + R_RXPIRQ, 0x0Fu);
    Xil_Out32(b + R_CR, 0x02u);         /* TX FIFO reset */
    Xil_Out32(b + R_CR, 0x01u);         /* enabled, dynamic mode */
    Xil_Out32(b + R_ISR, Xil_In32(b + R_ISR));
}

static int Push(UINTPTR b, u32 v)
{
    u32 t;
    for (t = 0; Xil_In32(b + R_SR) & SR_TXFULL; t++) { if (t >= LIMIT_US) return 0; usleep(1); }
    Xil_Out32(b + R_TX, v);
    return 1;
}

/* waits for the STOP to have gone out: FIFO empty and bus free. A finished read also sets ISR bit 1, so only writes
 * treat it as the missing acknowledge. */
static int Finish(UINTPTR b, u32 bad)
{
    u32 t;
    for (t = 0; t < LIMIT_US; t++) {
        const u32 sr = Xil_In32(b + R_SR);
        if (Xil_In32(b + R_ISR) & bad) return 0;
        if ((sr & SR_TXEMP) && !(sr & SR_BB)) return 1;
        usleep(1);
    }
    return 0;
}

static int Write(UINTPTR b, u8 a, const u8 *p, unsigned n)
{
    unsigned i;
    Prep(b);
    if (!Push(b, DYN_START | (u32)a << 1 | (n ? 0u : DYN_STOP))) return 0;
    for (i = 0; i < n; i++) if (!Push(b, p[i] | (i + 1 == n ? DYN_STOP : 0u))) return 0;
    return Finish(b, ISR_ARB | ISR_TXERR);
}

static int Read(UINTPTR b, u8 a, const u8 *w, unsigned wn, u8 *p, unsigned n)
{
    unsigned i, got = 0;
    u32 t;
    Prep(b);
    if (wn) {
        if (!Push(b, DYN_START | (u32)a << 1)) return 0;
        for (i = 0; i < wn; i++) if (!Push(b, w[i])) return 0;
    }
    if (!Push(b, DYN_START | (u32)a << 1 | 1u) || !Push(b, DYN_STOP | n)) return 0;
    for (t = 0; got < n && t < LIMIT_US; ) {
        if (!(Xil_In32(b + R_SR) & SR_RXEMP)) { p[got++] = (u8)Xil_In32(b + R_RX); continue; }
        if (Xil_In32(b + R_ISR) & ISR_ARB) return 0;
        usleep(1); t++;
    }
    return got == n && Finish(b, ISR_ARB);
}

unsigned IicSafeSend(UINTPTR b, u8 a, u8 *p, unsigned n, u8 opt)
{
    int k;
    if (opt != XIIC_STOP && n <= sizeof(Pend)) {     /* register address of a read: goes out with the read */
        for (k = 0; k < (int)n; k++) Pend[k] = p[k];
        PendN = n; PendAddr = a;
        return n;
    }
    PendN = 0;
    for (k = 0; k < TRIES; k++) {
        if (Write(b, a, p, n)) return n;
        IicErrors++;
        Prep(b);
        usleep(1000);
    }
    return 0;
}

unsigned IicSafeRecv(UINTPTR b, u8 a, u8 *p, unsigned n, u8 opt)
{
    const unsigned wn = PendAddr == a ? PendN : 0;
    int k;
    (void)opt;
    PendN = 0; PendAddr = 0xFF;
    for (k = 0; k < TRIES; k++) {
        if (Read(b, a, Pend, wn, p, n)) return n;
        IicErrors++;
        Prep(b);
        usleep(1000);
    }
    return 0;
}
