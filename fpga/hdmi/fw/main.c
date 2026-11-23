/* HDMI receiver control for the XCAP card (and the loopback transmitter in tx.c).
 * Brings up TMDS181 + Video PHY + HDMI RX subsystem, serves the EDID, follows
 * stream changes, and publishes the signal description to the capture core. */
#include <string.h>
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_exception.h"
#include "xil_io.h"
#include "xiic.h"
#include "iic_safe.h"
#include "xintc.h"
#include "mb_interface.h"
#include "sleep.h"
#include "xvphy.h"
#include "xv_hdmirxss.h"
#include "../edid.h"

#define FW_VERSION      0x00050006u
#define META_BASE       0x44B00000u
#define META(n)         (META_BASE + 4u * (n))
#define META_COMMIT     (META_BASE + 0x40u)
#define META_HOST_CTRL  (META_BASE + 0x48u)   /* reads of 0x40/0x48 give HOST_CTRL, 0x44/0x4C TX_CTRL. bit 0: hold HPD low, bit 4: advertise bitstream audio (Atmos),
                                                 bit 5: use the EDID in HOST_EDID, 15:8: its number (1..255) */
#define HOST_EDID       (META_BASE + 0x100u)
#define GPIO_BASE       0x40010000u
#define TMDS181_ADDR    0x5Cu

XVphy Vphy;
static XV_HdmiRxSs RxSs;
static XIntc Intc;
static u32 Meta[16];
extern u32 TxStatus;
int TxSetup(XIntc *intc);
void TxVphyCallbacks(void);
void TxPoll(void);
static u32 AtmosOn, EdidSel, CardFound;       /* EdidSel: 0 PCM, 1 Atmos, 0x100 | n host EDID number n */
static volatile u32 StreamUp, Changes, VphyErrors, Overflows, DrmAge, Eotf;
static volatile u32 Drm[6];                   /* HDR metadata as the callback got it; Meta[] belongs to the main loop alone */
static volatile u32 Now;                      /* main loop passes, 10 ms or more each */
static u32 Published;                         /* Changes when the description last went to the capture core */

/* Interrupts off, and back to what they were: for data that both the main loop and a callback work on. The callbacks
 * run with interrupts off already, so the same code may be called from either side. */
u32 IrqOff(void) { const u32 on = mfmsr() & 2u; microblaze_disable_interrupts(); return on; }
void IrqOn(u32 on) { if (on) microblaze_enable_interrupts(); }

static void Publish(void)
{
    u32 i;
    for (i = 0; i < 16; i++) Xil_Out32(META(i), Meta[i]);
    Xil_Out32(META_COMMIT, 1);
}

static int TmdsWrite(u8 reg, u8 val)
{
    u8 b[2];
    b[0] = reg; b[1] = val;
    return XIic_Send(XPAR_IIC_0_BASEADDR, TMDS181_ADDR, b, 2, XIIC_STOP) == 2;
}
static int TmdsRead(u8 reg)
{
    u8 b = reg;
    if (XIic_Send(XPAR_IIC_0_BASEADDR, TMDS181_ADDR, &b, 1, XIIC_REPEATED_START) != 1) return -1;
    if (XIic_Recv(XPAR_IIC_0_BASEADDR, TMDS181_ADDR, &b, 1, XIIC_STOP) != 1) return -1;
    return b;
}

/* ---------------------------------------------------------------- callbacks */

static void CbRxInit(void *Ref)
{
    XVphy *p = (XVphy *)Ref;
    XV_HdmiRxSs_RefClockChangeInit(&RxSs);
    p->HdmiRxTmdsClockRatio = RxSs.TMDSClockRatio;
    xil_printf("RX init: reference %d kHz, ratio %d\r\n", (int)(p->HdmiRxRefClkHz / 1000), (int)p->HdmiRxTmdsClockRatio);
}

static void CbRxReady(void *Ref)
{
    XVphy *p = (XVphy *)Ref;
    XVphy_ChannelId ch = XVphy_GetPllType(p, 0, XVPHY_DIR_RX, XVPHY_CHANNEL_ID_CH1) == XVPHY_PLL_TYPE_CPLL ?
        XVPHY_CHANNEL_ID_CH1 : XVPHY_CHANNEL_ID_CMN0;
    XV_HdmiRxSs_SetStream(&RxSs, p->HdmiRxRefClkHz, (u32)(XVphy_GetLineRateHz(p, 0, ch) / 1000000));
    xil_printf("RX ready: line rate %d Mb/s\r\n", (int)(XVphy_GetLineRateHz(p, 0, ch) / 1000000));
}

static void CbVphyError(void *Ref)
{
    static u32 last;
    (void)Ref;
    VphyErrors++;
    if (VphyErrors == 1u || Now - last >= 100u) {     /* a bad link raises thousands a second: one line a second */
        last = Now;
        xil_printf("VPHY error (%d so far)\r\n", (int)VphyErrors);
    }
}

static void CbConnect(void *Ref)
{
    XV_HdmiRxSs *r = (XV_HdmiRxSs *)Ref;
    xil_printf("cable %d\r\n", (int)r->IsStreamConnected);
    if (!r->IsStreamConnected) Vphy.HdmiRxTmdsClockRatio = 0;
    XVphy_IBufDsEnable(&Vphy, 0, XVPHY_DIR_RX, (u8)(r->IsStreamConnected ? TRUE : FALSE));
}

static void CbStreamInit(void *Ref)
{
    XV_HdmiRxSs *r = (XV_HdmiRxSs *)Ref;
    XVidC_VideoStream *v = XV_HdmiRxSs_GetVideoStream(r);
    /* 4:2:2 travels as 24 bits per pixel whatever its depth */
    XVidC_ColorDepth bpc = v->ColorFormatId == XVIDC_CSF_YCRCB_422 ? XVIDC_BPC_8 : v->ColorDepth;
    xil_printf("RX stream init %dx%d cs %d bpc %d\r\n", (int)v->Timing.HActive, (int)v->Timing.VActive, (int)v->ColorFormatId, (int)v->ColorDepth);
    if (XVphy_HdmiCfgCalcMmcmParam(&Vphy, 0, XVPHY_CHANNEL_ID_CH1, XVPHY_DIR_RX, v->PixPerClk, bpc) == XST_FAILURE) { xil_printf("RX MMCM params failed\r\n"); return; }
    XVphy_MmcmStart(&Vphy, 0, XVPHY_DIR_RX);
    usleep(10000);
}

/* loop-out (tx.c): the receiver's stream and the latest copy of each infoframe it forwards */
#define RX_AUX_N 6u
#define RX_AUX_VS 3u                                                  /* first of the two vendor specific places */
static const u8 RxAuxType[RX_AUX_N] = { 0x82, 0x84, 0x87, 0x81, 0x81, 0x83 };   /* AVI, audio, DRM (HDR), vendor specific x 2, source product */
static XHdmiC_Aux RxAux[RX_AUX_N];
static volatile u32 RxAuxAge[RX_AUX_N] = { 1000, 1000, 1000, 1000, 1000, 1000 };  /* 10 ms steps since it last came, 1000 = never */
XV_HdmiRxSs *RxSsGet(void) { return &RxSs; }
u32 RxUp(void) { return StreamUp; }
u32 RxChanges(void) { return Changes; }
const XHdmiC_Aux *RxAuxGet(u32 i, u32 *age) { if (i >= RX_AUX_N) return 0; *age = RxAuxAge[i]; return &RxAux[i]; }   /* callbacks only */

static void CbStreamUp(void *Ref)   { (void)Ref; StreamUp = 1; Changes++; DrmAge = 1000; xil_printf("RX up\r\n"); }
static void CbStreamDown(void *Ref) { u32 i; (void)Ref; StreamUp = 0; Changes++; for (i = 0; i < RX_AUX_N; i++) RxAuxAge[i] = 1000; xil_printf("RX down\r\n"); }
static void CbOverflow(void *Ref)   { (void)Ref; Overflows++; }
static void CbAux(void *Ref)
{
    XHdmiC_Aux *a = XV_HdmiRxSs_GetAuxiliary(&RxSs);
    u32 i;
    (void)Ref;
    if (a->Header.Byte[0] == 0x81) {             /* vendor specific: a source may send several (HDMI Forum, Dolby Vision ...), */
        const u8 *o = a->Data.Byte;              /* told apart by the IEEE number in payload bytes 1..3; two are kept */
        u32 s = RX_AUX_N;
        for (i = RX_AUX_VS; i < RX_AUX_VS + 2u; i++) {
            const u8 *p = RxAux[i].Data.Byte;
            if (RxAuxAge[i] < 1000u && o[1] == p[1] && o[2] == p[2] && o[3] == p[3]) { s = i; break; }
        }
        if (s == RX_AUX_N) s = RxAuxAge[RX_AUX_VS + 1u] > RxAuxAge[RX_AUX_VS] ? RX_AUX_VS + 1u : RX_AUX_VS;   /* a new one replaces the older */
        RxAux[s] = *a; RxAuxAge[s] = 0;
    }
    else for (i = 0; i < RX_AUX_N; i++) if (a->Header.Byte[0] == RxAuxType[i]) { RxAux[i] = *a; RxAuxAge[i] = 0; }
    if (a->Header.Byte[0] == 0x87) {             /* dynamic range and mastering infoframe */
        u32 k;
        u8 pb[28];
        for (k = 0; k < 28; k++) pb[k] = a->Data.Byte[(k / 7) * 8 + k % 7];
#define W(n) ((u32)pb[n] | (u32)pb[(n) + 1] << 8)
        Drm[0] = W(3)  | W(5)  << 16;
        Drm[1] = W(7)  | W(9)  << 16;
        Drm[2] = W(11) | W(13) << 16;
        Drm[3] = W(15) | W(17) << 16;
        Drm[4] = W(19) | W(21) << 16;            /* max | min mastering luminance */
        Drm[5] = W(23) | W(25) << 16;            /* MaxCLL | MaxFALL */
        Eotf = pb[1] & 7u;
        DrmAge = 0;
#undef W
    }
}

/* ---------------------------------------------------------------- main loop */

static void Describe(void)
{
    XVidC_VideoStream *v = XV_HdmiRxSs_GetVideoStream(&RxSs);
    XHdmiC_AVI_InfoFrame *avi = XV_HdmiRxSs_GetAviInfoframe(&RxSs);
    u32 flags = 0, cs, rate = 0, w, h;
    int hdr = StreamUp && DrmAge < 100;

    Meta[1] = Drm[0]; Meta[2] = Drm[1]; Meta[3] = Drm[2]; Meta[4] = Drm[3]; Meta[6] = Drm[4]; Meta[7] = Drm[5];

    w = v->Timing.HActive;
    h = v->Timing.VActive;
    cs = v->ColorFormatId == XVIDC_CSF_RGB ? 0 : v->ColorFormatId == XVIDC_CSF_YCRCB_422 ? 1 : v->ColorFormatId == XVIDC_CSF_YCRCB_444 ? 2 : 3;
    if (StreamUp && v->Timing.HTotal && v->Timing.F0PVTotal) {
        /* measured pixel clock -> frame rate in mHz */
        u64 pix = (u64)RxSs.HdmiRxPtr->Stream.PixelClk;
        rate = (u32)(pix * 1000ull / ((u64)v->Timing.HTotal * v->Timing.F0PVTotal));
    }
    if (hdr) flags |= 1u | (Eotf << 4);
    if (avi->Colorimetry == XHDMIC_COLORIMETRY_EXTENDED &&
        (avi->ExtendedColorimetry == 5 || avi->ExtendedColorimetry == 6)) flags |= 2u;   /* BT.2020 */
    if (cs == 0 ? avi->QuantizationRange == 2 : avi->YccQuantizationRange == 1) flags |= 4u;
    {   /* audio: rate / 100 Hz | channels << 16 | format << 24 (0 none, 1 L-PCM packets, 2 HBR) */
        XV_HdmiRx *rx = RxSs.HdmiRxPtr;
        u32 n = XV_HdmiRx_GetAcrN(rx), cts = XV_HdmiRx_GetAcrCts(rx), fs = 0, fmt;
        XV_HdmiRx_AudioFormatType f = XV_HdmiRxSs_GetAudioFormat(&RxSs);
        u64 tmds = (u64)Vphy.HdmiRxRefClkHz * (Vphy.HdmiRxTmdsClockRatio ? 4u : 1u);
        if (cts && StreamUp) fs = (u32)(tmds * n / (128ull * cts));
        fmt = !StreamUp || !fs ? 0 : f == XV_HDMIRX_AUDFMT_HBR ? 2 : 1;
        Meta[5] = ((fs + 50) / 100) | (u32)XV_HdmiRxSs_GetAudioChannels(&RxSs) << 16 | fmt << 24;
    }
    Meta[0]  = flags;
    Meta[8]  = rate;
    Meta[9]  = StreamUp ? (w | h << 16) : 0;
    Meta[10] = (StreamUp ? 1u : 0u) | cs << 1 | (u32)AtmosOn << 4 | (EdidSel >= 0x100u ? 0x20u | (EdidSel & 255u) << 24 : 0u) | CardFound << 6 | (RxSs.IsStreamConnected ? 0x80u : 0u) | (u32)v->ColorDepth << 8 | (u32)XV_HdmiRxSs_GetVideoIDCode(&RxSs) << 16;
    Meta[11] = (Changes & 0xFFFFu) | TxStatus << 16;
    Meta[12] = (VphyErrors > 0xFFFFu ? 0xFFFFu : VphyErrors) | (Overflows > 0xFFFFu ? 0xFFFFu : Overflows) << 16;
    Meta[13] = FW_VERSION;
    Meta[14]++;
    Meta[15] = (u32)(Vphy.HdmiRxRefClkHz / 1000);
}

/* The description of the signal for the capture core, taken and handed over in one piece: the callbacks that change
 * the stream cannot run in the middle (about 0.1 ms with interrupts off). Main loop only. */
void MetaRefresh(void)
{
    const u32 irq = IrqOff();
    Published = Changes;
    Describe();
    Publish();
    IrqOn(irq);
}

/* for the slow steps of the main loop (tx.c): a stream change that came meanwhile goes out now, not when they end */
void MetaPoll(void) { if (Changes != Published) MetaRefresh(); }

int main(void)
{
    XVphy_Config *vc;
    XV_HdmiRxSs_Config *rc;
    u32 loops = 0, hold = 0, refused = ~0u;
    int id;

    xil_printf("\r\nXCAP HDMI RX firmware %08x\r\n", FW_VERSION);
    Xil_Out32(GPIO_BASE, 0x0);                    /* pulse the card enables like the vendor example: this also frees an I2C */
    usleep(50000);                                /* bus a slave was left holding low */
    Xil_Out32(GPIO_BASE, 0x3);                    /* card clock chip out of reset */
    XIic_WriteReg(XPAR_IIC_0_BASEADDR, XIIC_RESETR_OFFSET, XIIC_RESET_MASK);  /* a restarted CPU finds the controller as it was */
    memset(Meta, 0, sizeof(Meta));
    Meta[13] = FW_VERSION;
    Publish();
    usleep(100000);
    id = TmdsRead(0x00);
    xil_printf("TMDS181 id %x, config %s\r\n", id, TmdsWrite(0x0C, 0x61) ? "ok" : "FAILED");
    CardFound = id >= 0;

    Xil_ExceptionInit();
    if (XIntc_Initialize(&Intc, XPAR_INTC_0_DEVICE_ID) != XST_SUCCESS || XIntc_Start(&Intc, XIN_REAL_MODE) != XST_SUCCESS) return 1;
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT, (Xil_ExceptionHandler)XIntc_InterruptHandler, &Intc);

    TxSetup(&Intc);
    XV_HdmiRxSs_SetEdidParam(&RxSs, (u8 *)XcapEdidPcm, sizeof(XcapEdidPcm));
    rc = XV_HdmiRxSs_LookupConfig(XPAR_XV_HDMIRX_0_DEVICE_ID);
    if (!rc || XV_HdmiRxSs_CfgInitialize(&RxSs, rc, rc->BaseAddress) != XST_SUCCESS) { xil_printf("RXSS init failed\r\n"); Meta[10] = 0xE1u << 24; Publish(); return 1; }
    XIntc_Connect(&Intc, XPAR_INTC_0_V_HDMIRXSS_0_VEC_ID, (XInterruptHandler)XV_HdmiRxSS_HdmiRxIntrHandler, &RxSs);
    XIntc_Enable(&Intc, XPAR_INTC_0_V_HDMIRXSS_0_VEC_ID);
    XV_HdmiRxSs_SetCallback(&RxSs, XV_HDMIRXSS_HANDLER_CONNECT, (void *)CbConnect, &RxSs);
    XV_HdmiRxSs_SetCallback(&RxSs, XV_HDMIRXSS_HANDLER_AUX, (void *)CbAux, &RxSs);
    XV_HdmiRxSs_SetCallback(&RxSs, XV_HDMIRXSS_HANDLER_BRDGOVERFLOW, (void *)CbOverflow, &RxSs);
    XV_HdmiRxSs_SetCallback(&RxSs, XV_HDMIRXSS_HANDLER_STREAM_INIT, (void *)CbStreamInit, &RxSs);
    XV_HdmiRxSs_SetCallback(&RxSs, XV_HDMIRXSS_HANDLER_STREAM_UP, (void *)CbStreamUp, &RxSs);
    XV_HdmiRxSs_SetCallback(&RxSs, XV_HDMIRXSS_HANDLER_STREAM_DOWN, (void *)CbStreamDown, &RxSs);

    vc = XVphy_LookupConfig(XPAR_VPHY_0_DEVICE_ID);
    XIntc_Connect(&Intc, XPAR_INTC_0_VPHY_0_VEC_ID, (XInterruptHandler)XVphy_InterruptHandler, &Vphy);
    if (!vc || XVphy_Hdmi_CfgInitialize(&Vphy, 0, vc) != XST_SUCCESS) { xil_printf("VPHY init failed\r\n"); Meta[10] = 0xE2u << 24; Publish(); return 1; }
    XIntc_Enable(&Intc, XPAR_INTC_0_VPHY_0_VEC_ID);
    XVphy_SetHdmiCallback(&Vphy, XVPHY_HDMI_HANDLER_RXINIT, (void *)CbRxInit, &Vphy);
    XVphy_SetHdmiCallback(&Vphy, XVPHY_HDMI_HANDLER_RXREADY, (void *)CbRxReady, &Vphy);
    XVphy_SetErrorCallback(&Vphy, (void *)CbVphyError, &Vphy);
    TxVphyCallbacks();
    Xil_ExceptionEnable();
    XV_HdmiRxSs_Start(&RxSs);
    xil_printf("ready\r\n");

    for (;;) {
        u32 ctl = Xil_In32(META_HOST_CTRL), want = ctl & 1u, sel = (ctl & 0x20u) ? 0x100u | ((ctl >> 8) & 255u) : (ctl >> 4) & 1u;
        usleep(10000);
        loops++;
        Now = loops;
        {   /* the callbacks set these ages to 0 */
            const u32 irq = IrqOff();
            u32 i;
            if (DrmAge < 1000) DrmAge++;
            for (i = 0; i < RX_AUX_N; i++) if (RxAuxAge[i] < 1000) RxAuxAge[i]++;
            IrqOn(irq);
        }
        if (want != hold) {                       /* the host asks for a fresh hot plug */
            hold = want;
            if (hold) { XVphy_IBufDsEnable(&Vphy, 0, XVPHY_DIR_RX, FALSE); XV_HdmiRxSs_Stop(&RxSs); StreamUp = 0; MetaRefresh(); }
            else      { XV_HdmiRxSs_Start(&RxSs); XVphy_IBufDsEnable(&Vphy, 0, XVPHY_DIR_RX, TRUE); }
        }
        if (sel != EdidSel && sel != refused && !hold) {   /* other capabilities: new EDID and a fresh hot plug */
            static u8 buf[256];
            const u8 *e = sel == 1u ? XcapEdidAtmos : XcapEdidPcm;
            if (sel >= 0x100u) {
                u32 k, s0 = 0, s1 = 0;
                for (k = 0; k < 64; k++) { u32 v = Xil_In32(HOST_EDID + 4u * k); buf[4 * k] = v; buf[4 * k + 1] = v >> 8; buf[4 * k + 2] = v >> 16; buf[4 * k + 3] = v >> 24; }
                for (k = 0; k < 128; k++) { s0 += buf[k]; s1 += buf[128 + k]; }
                if ((s0 & 255u) || (s1 & 255u) || buf[0] || buf[1] != 0xFF || buf[126] != 1 || buf[128] != 2) { refused = sel; xil_printf("host EDID refused\r\n"); continue; }
                e = buf;
            }
            refused = ~0u;
            EdidSel = sel;
            AtmosOn = sel == 1u;
            xil_printf("EDID %x\r\n", sel);
            XVphy_IBufDsEnable(&Vphy, 0, XVPHY_DIR_RX, FALSE);
            XV_HdmiRxSs_Stop(&RxSs);
            StreamUp = 0;
            MetaRefresh();                            /* "no signal" reaches the capture core before the pause, not after it */
            usleep(600000);
            XV_HdmiRxSs_LoadEdid(&RxSs, (u8 *)e, 256);
            XV_HdmiRxSs_Start(&RxSs);
            XVphy_IBufDsEnable(&Vphy, 0, XVPHY_DIR_RX, TRUE);
        }
        MetaPoll();                                   /* a new signal format: tell the capture core before anything slow */
        TxPoll();
        if (loops == 1500u && !StreamUp) {            /* 15 s without a picture: leave the details in the log */
            xil_printf("--- RX not up after 15 s\r\n");
            XV_HdmiRxSs_LogDisplay(&RxSs);
            XV_HdmiRxSs_ReportInfo(&RxSs);
            XVphy_LogDisplay(&Vphy);
        }
        if (loops % 5 == 0 || Changes != Published) MetaRefresh();
    }
}
