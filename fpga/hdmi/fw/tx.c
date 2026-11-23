/* HDMI transmitter of the XCAP card, for loopback tests (cable from HDMI OUT to HDMI IN).
 * Sends the AMD test pattern generator's colour bars at 4K60 4:2:2 12-bit (or the other modes below), the
 * AVI / audio / HDR10 infoframes, and the counting audio of xcap_txaudio. Controlled by the host's TX_CTRL:
 *   bit 0 on, bits 3:1 mode, bits 7:4 audio (0 off, 1 two channels, 2 eight channels), bit 8 second HDR metadata set,
 *   bit 9 act as if a sink were connected (loopback: the card does not pass the hot plug through),
 *   bits 31:16 a number that restarts the stream when it changes.
 * Loop-out (default whenever bit 0 is clear): the received picture, sound and infoframes go out unchanged, with the
 * clock chip locked to the receiver's TMDS clock. TX_CTRL bit 10 turns it off; bit 9 also works here (no sink needed).
 * TX status (Meta[11] 31:16) bits 7:4 read 0xE while the loop-out runs. */
#include <string.h>
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xiic.h"
#include "iic_safe.h"
#include "xintc.h"
#include "sleep.h"
#include "xvphy.h"
#include "xv_hdmitxss.h"
#include "xv_hdmirxss.h"
#include "xv_hdmitx.h"
#include "xv_tpg.h"
#include "dp159.h"
#include "idt_8t49n24x.h"

#define META_BASE     0x44B00000u
#define TX_CTRL       (META_BASE + 0x4Cu)   /* address bit 2 set: TX_CTRL, see xcap_meta_regs.sv */
#define AUD_N         (META_BASE + 0x80u)
#define AUD_CTS       (META_BASE + 0x84u)
#define AUD_RATE      (META_BASE + 0x88u)
#define AUD_CFG       (META_BASE + 0x8Cu)
#define AUD_STAT      (META_BASE + 0x90u)   /* read only, what the receiver's sound is (xcap_audfmt): bit 0 channel status says "not PCM",
                                               bit 1 IEC 61937 bursts seen, bit 2 channel status seen, 12:8 data type of the bursts */
#define GPIO_BASE     0x40010000u
#define IDT_ADDR      0x7Cu

extern XVphy Vphy;
static XV_HdmiTxSs TxSs;
static XV_tpg Tpg;
static u32 Applied = ~0u, Want, Seen;
static volatile u32 Connected, StreamUp, NeedRetimer, Ups, Downs;
static u64 LineRate;
u32 TxStatus;                               /* reported to the host in Meta[11] 31:16 */

/* loop-out: receiver side lives in main.c */
XV_HdmiRxSs *RxSsGet(void);
u32 RxUp(void);
u32 RxChanges(void);
const XHdmiC_Aux *RxAuxGet(u32 i, u32 *age);
u32 IrqOff(void);
void IrqOn(u32 on);
void MetaPoll(void);
#define PT_VIDEO 0x100u                     /* AUD_CFG bits read by xcap_hdmi_top: picture and sound of the receiver */
#define PT_AUDIO 0x200u
static u32 PtActive, PtChanges, PtFailed;   /* PtFailed: this receiver stream could not be passed on, wait for the next */
static volatile u32 PtRestart;              /* a sink was plugged in: start the loop-out again for it */
static u32 SinkHbr, SinkEdidOk, SinkEdidTries;                         /* the loop-out sink's EDID lists DTS-HD or Dolby TrueHD/MAT (Atmos) */
static u32 SinkCodes;                       /* bit n: the sink's EDID lists CTA-861 audio format code n (2 AC-3, 7 DTS, 10 E-AC-3 ...) */
static u32 PtAudKey, PtAudNew, PtAudSeen;   /* receiver audio (format code << 16 | format << 8 | channels) the transmitter is set for */
static u32 PtAudMuted;                      /* the sink cannot take what the source sends: no sound rather than noise */
static u8 Edid[512];

/* Which compressed formats may be passed on: read from the sink's CTA extension (short audio descriptors). A sink
   that is not asked for bitstream audio plays it as PCM, i.e. very loud noise, so anything unknown counts as no. */
/* short audio descriptors of one CTA-861 extension block: bit n audio format code n is listed (11 DTS-HD, 12 Dolby
   TrueHD/MAT: the HBR ones), bits 16+ PCM channels */
static u32 CtaAudio(const u8 *b)
{
    u32 i, d = b[2], codes = 0, pcmCh = 0;
    if (b[0] != 0x02u) return 0;
    if (d > 127u || d < 4u) d = 127u;
    for (i = 4; i < d; i += 1u + (b[i] & 31u)) {
        const u32 tag = b[i] >> 5, len = b[i] & 31u;
        u32 k;
        if (tag != 1u) continue;
        for (k = 0; k + 3u <= len && i + 1u + k + 2u < 128u; k += 3u) {
            const u8 *sad = &b[i + 1 + k];
            const u32 code = (sad[0] >> 3) & 15u;
            codes |= 1u << code;
            if (code == 1u && (sad[0] & 7u) + 1u > pcmCh) pcmCh = (sad[0] & 7u) + 1u;
        }
    }
    return codes | pcmCh << 16;
}

static void ReadSinkAudio(void)
{
    u32 n, i, a = 0, blocks;
    int st = XV_HdmiTxSs_ReadEdid(&TxSs, Edid);
    SinkEdidTries++;
    if (st == XST_SUCCESS && Edid[0] == 0x00u && Edid[1] == 0xFFu) {
        n = Edid[126];
        blocks = 2;
        if (n >= 2u && XV_HdmiTxSs_ReadEdidSegment(&TxSs, Edid + 256, 1) == XST_SUCCESS) blocks = 4;
        for (i = 1; i <= n && i < blocks; i++) {
            const u32 c = CtaAudio(Edid + 128u * i);
            a |= c & 0xFFFFu;
            if ((c >> 16) > (a >> 16)) a = (a & 0xFFFFu) | (c & ~0xFFFFu);
        }
        SinkEdidOk = 1;
        xil_printf("sink EDID: %d extension blocks (%02x %02x %02x), PCM %d ch, audio formats %04x, HBR bitstream %s\r\n", (int)n, Edid[128],
            blocks > 2 ? Edid[256] : 0, blocks > 2 ? Edid[384] : 0, (int)(a >> 16), (int)(a & 0xFFFFu), (a & 0x1800u) ? "yes" : "no");
    } else xil_printf("sink EDID not read (status %d, connected %d): no bitstream audio\r\n", st, (int)TxSs.IsStreamConnected);
    SinkCodes = a & 0xFFFEu;                    /* code 0 is no format: an unidentified bitstream never passes */
    SinkHbr = (a & 0x1800u) != 0u;
}

/* What the receiver's two-channel (not HBR) sound packets carry, as the CTA-861 audio format code a sink has to list
 * for it: 1 linear PCM (also while nothing is known yet), 0 a bitstream that is not identified (yet). The audio
 * infoframe does not say (HDMI sources leave its coding type at "see stream"), so this comes from the stream itself:
 * channel status bit 1 and the data type of the IEC 61937 bursts, both watched by xcap_audfmt. */
static u32 RxAudCode(void)
{
    const u32 s = Xil_In32(AUD_STAT);
    if ((s & 5u) != 5u) return 1u;
    if (!(s & 2u)) return 0u;
    switch ((s >> 8) & 31u) {
    case 1u:  return 2u;                    /* AC-3 */
    case 7u:  return 6u;                    /* AAC */
    case 11u: case 12u: case 13u: return 7u;   /* DTS */
    case 17u: return 11u;                   /* DTS-HD */
    case 21u: return 10u;                   /* E-AC-3 */
    case 22u: return 12u;                   /* MAT (Dolby TrueHD) */
    default:  return 0u;
    }
}

static u32 RxAudKey(void)
{
    XV_HdmiRxSs *r = RxSsGet();
    const u32 f = (u32)XV_HdmiRxSs_GetAudioFormat(r);
    u32 ch = XV_HdmiRxSs_GetAudioChannels(r);
    if (ch < 2u) ch = 2u;
    return (f == (u32)XV_HDMIRX_AUDFMT_HBR ? 0u : RxAudCode() << 16) | (f & 0xFFu) << 8 | ch;
}

/* transmitter sound for what the receiver gets now; also when the source changes format in the middle of a stream.
 * Runs in the stream-up callback and in the main loop, there with interrupts off. */
static void PtAudio(XV_HdmiTxSs *t)
{
    XV_HdmiRxSs *r = RxSsGet();
    const u32 key = RxAudKey(), hbr = ((key >> 8) & 0xFFu) == (u32)XV_HDMIRX_AUDFMT_HBR, code = key >> 16;
    Xil_Out32(AUD_CFG, 0x1u | PT_VIDEO);
    XV_HdmiTxSs_AudioMute(t, TRUE);
    XV_HdmiTxSs_SetAudioChannels(t, (u8)(key & 0xFFu));
    XV_HdmiTxSs_SetAudioFormat(t, hbr ? XV_HDMITX_AUDFMT_HBR : XV_HDMITX_AUDFMT_LPCM);
    Xil_Out32(AUD_N, XV_HdmiRx_GetAcrN(r->HdmiRxPtr));
    Xil_Out32(AUD_CTS, XV_HdmiRx_GetAcrCts(r->HdmiRxPtr));
    PtAudKey = PtAudNew = key;
    PtAudSeen = 0;
    PtAudMuted = hbr ? !SinkHbr : code != 1u && !((SinkCodes >> code) & 1u);   /* code 0 (unknown) is never listed */
    if (!PtAudMuted) {
        XV_HdmiTxSs_AudioMute(t, FALSE);
        Xil_Out32(AUD_CFG, 0x1u | PT_VIDEO | PT_AUDIO);
    }
    xil_printf("loop-out audio: %d ch%s (format code %d)%s\r\n", (int)(key & 0xFFu), hbr ? " HBR bitstream" : code == 1u ? " PCM" : " bitstream",
        (int)code, PtAudMuted ? ", muted (sink does not take it)" : "");
}

static void Gpio(u32 bits) { Xil_Out32(GPIO_BASE, bits); }

/* Resets the I2C controller only once the last transfer has really ended. A reset while the STOP of the previous
 * write is still on the wire left the TMDS181 holding SDA low, and the controller then waits forever for its START. */
static void IicQuiet(void)
{
    u32 t, sr;
    for (t = 0; t < 2000; t++) {
        sr = XIic_ReadReg(XPAR_IIC_0_BASEADDR, XIIC_SR_REG_OFFSET);
        if (!(sr & XIIC_SR_BUS_BUSY_MASK) && (sr & XIIC_SR_TX_FIFO_EMPTY_MASK)) break;
        usleep(10);
    }
    usleep(500);
    XIic_WriteReg(XPAR_IIC_0_BASEADDR, XIIC_RESETR_OFFSET, XIIC_RESET_MASK);
    usleep(100);
}

/* The clock chip runs free (no input reference), so its digital PLL never locks and the LOL flag on GPIO[3] stays
 * high. The Video PHY takes that pin (inverted) as "TX reference ready" and does not even measure the clock while it
 * is high. GPIO[3] becomes a plain output (registers 0036h GPO3SEL = 000, 0038h GPO3 = the level): high while the
 * chip is being set and until its output is final, so the Video PHY starts once, on the final clock; low from then on.
 * The level is written first: the pin does not pass through the other level when it leaves the LOL function. */
static int IdtLol(u32 high)
{
    u8 a[3] = { 0x00, 0x38, high ? 0x08 : 0x00 }, b[3] = { 0x00, 0x36, 0x00 };
    return XIic_Send(XPAR_IIC_0_BASEADDR, IDT_ADDR, a, 3, XIIC_STOP) == 3 &&
           XIic_Send(XPAR_IIC_0_BASEADDR, IDT_ADDR, b, 3, XIIC_STOP) == 3;
}

static u32 Ticks, StartedAt, Dumped;

/* The clock chip's output is not final when IDT_8T49N24x_SetClock() returns: its PLL calibration moves the frequency for
 * another 186 ms (measured: Video PHY lock events 53, 57, 131 and 186 ms after the last register write, the same in every
 * run). The Video PHY starts on the first sign of the clock, so the last of these steps arrived after the final stream up:
 * the QPLL kept its lock, only the TX MMCM (video clock) slipped, nothing restarted the stream, and the HDMI TX core sent
 * control characters for ever. So: wait until the clock is final, then have the Video PHY measure it and start again. */
#define IDT_SETTLE_TICKS 30u                /* TxPoll calls, 10 ms or more each */
static u32 SettleAt, Settling, SettleTries;

static void CbConnect(void *Ref)
{
    XV_HdmiTxSs *t = (XV_HdmiTxSs *)Ref;
    Connected = t->IsStreamConnected;
    XVphy_IBufDsEnable(&Vphy, 0, XVPHY_DIR_TX, Connected ? TRUE : FALSE);
    if (Connected) { Applied = ~0u; PtRestart = 1; }  /* start again for the new sink */
    xil_printf("TX cable %d\r\n", (int)Connected);
}

static void CbTxInit(void *Ref) { (void)Ref; XV_HdmiTxSs_RefClockChangeInit(&TxSs); }
static void CbTxReady(void *Ref) { (void)Ref; }

static void SendInfoframes(XV_HdmiTxSs *t)
{
    XHdmiC_Aux aux;
    XHdmiC_DRMInfoFrame drm;
    const u32 mode = (Applied >> 1) & 7u;
    if (PtActive) {                                   /* loop-out: whatever the source sent within the last second */
        const XHdmiC_Aux *a;                          /* (AVI, audio, HDR, two vendor specific; source product: 3 s, it may come once a second) */
        u32 i, age;
        for (i = 0; (a = RxAuxGet(i, &age)) != 0; i++)
            if (age < (i == 5u ? 300u : 100u) && !(i == 1u && PtAudMuted)) { aux = *a; XV_HdmiTxSs_SendGenericAuxInfoframe(t, &aux); }
        return;
    }
    aux = XV_HdmiC_AVIIF_GeneratePacket(XV_HdmiTxSs_GetAviInfoframe(t));
    XV_HdmiTxSs_SendGenericAuxInfoframe(t, &aux);
    aux = XV_HdmiC_AudioIF_GeneratePacket(XV_HdmiTxSs_GetAudioInfoframe(t));
    XV_HdmiTxSs_SendGenericAuxInfoframe(t, &aux);
    if (mode == 0 || mode == 3) {                     /* HDR10: ST 2084, BT.2020 primaries, D65 */
        memset(&drm, 0, sizeof(drm));
        drm.EOTF = XHDMIC_DRM_SMPTE_ST_2084;
        drm.Static_Metadata_Descriptor_ID = XHDMIC_DRM_STATIC_METADATA_TYPE1;
        drm.disp_primaries[0].x = 35400; drm.disp_primaries[0].y = 14600;    /* G R B order as CTA-861.3 does not mandate */
        drm.disp_primaries[1].x = 8500;  drm.disp_primaries[1].y = 39850;
        drm.disp_primaries[2].x = 6550;  drm.disp_primaries[2].y = 2300;
        drm.white_point.x = 15635; drm.white_point.y = 16450;
        drm.Max_Disp_Mastering_Luminance = (Applied & 0x100u) ? 4000 : 1000;
        drm.Min_Disp_Mastering_Luminance = 50;
        drm.Max_Content_Light_Level = (Applied & 0x100u) ? 3000 : 987;
        drm.Max_Frame_Average_Light_Level = (Applied & 0x100u) ? 800 : 321;
        XV_HdmiC_DRMIF_GeneratePacket(&drm, &aux);
        XV_HdmiTxSs_SendGenericAuxInfoframe(t, &aux);
    }
}

static void CbVsync(void *Ref) { SendInfoframes((XV_HdmiTxSs *)Ref); }

static void CbStreamUp(void *Ref)
{
    XV_HdmiTxSs *t = (XV_HdmiTxSs *)Ref;
    XVidC_VideoStream *s = XV_HdmiTxSs_GetVideoStream(t);
    XVphy_PllType pll = XVphy_GetPllType(&Vphy, 0, XVPHY_DIR_TX, XVPHY_CHANNEL_ID_CH1);
    const u32 audio = (Applied >> 4) & 15u, ch = audio == 2 ? 8 : 2;
    u64 tmds;
    LineRate = XVphy_GetLineRateHz(&Vphy, 0, pll == XVPHY_PLL_TYPE_CPLL ? XVPHY_CHANNEL_ID_CH1 :
        (pll == XVPHY_PLL_TYPE_QPLL || pll == XVPHY_PLL_TYPE_QPLL0) ? XVPHY_CHANNEL_ID_CMN0 : XVPHY_CHANNEL_ID_CMN1);
    XV_HdmiTxSS_SetHdmiMode(t);
    XV_HdmiTxSs_SetSamplingRate(t, Vphy.HdmiTxSampleRate);
    if (PtActive) {                                   /* loop-out: the TPG passes the receiver's picture through */
        XV_HdmiRxSs *r = RxSsGet();
        const XV_HdmiRx_AudioFormatType f = XV_HdmiRxSs_GetAudioFormat(r);
        u8 rch = XV_HdmiRxSs_GetAudioChannels(r);
        Xil_Out32(AUD_CFG, 0);
        Gpio(0x3); usleep(100); Gpio(0x7); usleep(100);   /* TPG reset; this is a callback, so no longer than needed */
        XV_tpg_DisableAutoRestart(&Tpg);
        XV_tpg_Set_height(&Tpg, s->Timing.VActive);
        XV_tpg_Set_width(&Tpg, s->Timing.HActive);
        XV_tpg_Set_colorFormat(&Tpg, s->ColorFormatId);
        XV_tpg_Set_bckgndId(&Tpg, XTPG_BKGND_COLOR_BARS);
        XV_tpg_Set_ovrlayId(&Tpg, 0);
        XV_tpg_Set_enableInput(&Tpg, 1);
        XV_tpg_Set_passthruStartX(&Tpg, 0);         /* the input only replaces the pattern inside this window */
        XV_tpg_Set_passthruStartY(&Tpg, 0);
        XV_tpg_Set_passthruEndX(&Tpg, s->Timing.HActive);
        XV_tpg_Set_passthruEndY(&Tpg, s->Timing.VActive);
        XV_tpg_EnableAutoRestart(&Tpg);
        XV_tpg_Start(&Tpg);
        memcpy(XV_HdmiTxSs_GetAviInfoframe(t), XV_HdmiRxSs_GetAviInfoframe(r), sizeof(XHdmiC_AVI_InfoFrame));
        if (rch < 2) rch = 2;
        PtAudio(t);
        StreamUp = 1;
        NeedRetimer = 1;
        Ups++;
        xil_printf("loop-out up %d x %d, %d ch audio%s, line rate %d Mb/s\r\n", (int)s->Timing.HActive, (int)s->Timing.VActive,
            (int)rch, f == XV_HDMIRX_AUDFMT_HBR ? " HBR" : "", (int)(LineRate / 1000000));
        return;
    }
    /* test pattern: reset, then colour bars in the stream's size and colour format */
    Gpio(0x3); usleep(100); Gpio(0x7); usleep(100);
    XV_tpg_DisableAutoRestart(&Tpg);
    XV_tpg_Set_height(&Tpg, s->Timing.VActive);
    XV_tpg_Set_width(&Tpg, s->Timing.HActive);
    XV_tpg_Set_colorFormat(&Tpg, s->ColorFormatId);
    XV_tpg_Set_bckgndId(&Tpg, XTPG_BKGND_COLOR_BARS);
    XV_tpg_Set_ovrlayId(&Tpg, 0);
    XV_tpg_Set_enableInput(&Tpg, 0);
    XV_tpg_EnableAutoRestart(&Tpg);
    XV_tpg_Start(&Tpg);
    /* audio: 48 kHz linear PCM, ACR from the TMDS character rate */
    tmds = XV_HdmiTxSs_GetTmdsClockFreqHz(t);
    Xil_Out32(AUD_CFG, 0);
    if (audio) {
        XHdmiC_AudioInfoFrame *a = XV_HdmiTxSs_GetAudioInfoframe(t);
        memset(a, 0, sizeof(*a));
        a->ChannelCount = (XHdmiC_AudioChannelCount)(ch - 1);
        a->ChannelAllocation = ch == 8 ? 0x13 : 0x00;
        XV_HdmiTxSs_SetAudioChannels(t, (u8)ch);
        XV_HdmiTxSs_SetAudioFormat(t, XV_HDMITX_AUDFMT_LPCM);
        XV_HdmiTxSs_AudioMute(t, FALSE);
        Xil_Out32(AUD_N, 6144);
        Xil_Out32(AUD_CTS, (u32)(tmds * 6144u / (128u * 48000u)));
        Xil_Out32(AUD_RATE, 48000u * ch);
        Xil_Out32(AUD_CFG, 0x1u | 0x2u | ch << 4);
    } else XV_HdmiTxSs_AudioMute(t, TRUE);
    StreamUp = 1;
    NeedRetimer = 1;
    Ups++;
    xil_printf("TX up %d x %d, line rate %d Mb/s, TMDS %d kHz\r\n", (int)s->Timing.HActive, (int)s->Timing.VActive, (int)(LineRate / 1000000), (int)(tmds / 1000));
}

static void CbStreamDown(void *Ref) { (void)Ref; StreamUp = 0; Downs++; Xil_Out32(AUD_CFG, 0); xil_printf("TX down\r\n"); }

static void Start(u32 ctl)
{
    static const struct { XVidC_VideoMode vm; XVidC_ColorFormat cf; XVidC_ColorDepth bpc; } modes[8] = {
        {XVIDC_VM_3840x2160_60_P, XVIDC_CSF_YCRCB_422, XVIDC_BPC_12},     /* 0 4K60 HDR10 */
        {XVIDC_VM_3840x2160_60_P, XVIDC_CSF_YCRCB_422, XVIDC_BPC_12},     /* 1 4K60 SDR */
        {XVIDC_VM_1920x1080_60_P, XVIDC_CSF_RGB, XVIDC_BPC_8},            /* 2 1080p60 RGB */
        {XVIDC_VM_3840x2160_30_P, XVIDC_CSF_YCRCB_422, XVIDC_BPC_12},     /* 3 4K30 HDR10 */
        {XVIDC_VM_3840x2160_60_P, XVIDC_CSF_RGB, XVIDC_BPC_8},            /* 4 4K60 RGB SDR */
        {XVIDC_VM_1920x1080_60_P, XVIDC_CSF_YCRCB_422, XVIDC_BPC_12},
        {XVIDC_VM_1920x1080_60_P, XVIDC_CSF_YCRCB_422, XVIDC_BPC_12},
        {XVIDC_VM_1920x1080_60_P, XVIDC_CSF_YCRCB_422, XVIDC_BPC_12}};
    const u32 m = (ctl >> 1) & 7u;
    XHdmiC_AVI_InfoFrame *avi = XV_HdmiTxSs_GetAviInfoframe(&TxSs);
    u64 tmds;
    Applied = ctl;
    StreamUp = 0;
    Settling = 0;
    XV_HdmiTxSs_Stop(&TxSs);
    TxSs.HdmiTxPtr->Stream.IsHdmi20 = TRUE;     /* both sinks here (our receiver, the TV) are HDMI 2.0; no EDID is read */
    tmds = XV_HdmiTxSs_SetStream(&TxSs, modes[m].vm, modes[m].cf, modes[m].bpc, NULL);
    memset(avi, 0, sizeof(*avi));
    avi->Version = 2;
    avi->ColorSpace = XV_HdmiC_XVidC_To_IfColorformat(modes[m].cf);
    avi->VIC = TxSs.HdmiTxPtr->Stream.Vic;
    avi->PicAspectRatio = XHDMIC_PIC_ASPECT_RATIO_16_9;
    if (m == 0 || m == 3) { avi->Colorimetry = XHDMIC_COLORIMETRY_EXTENDED; avi->ExtendedColorimetry = (XHdmiC_ExtendedColorimetry)6; }
    else if (modes[m].cf != XVIDC_CSF_RGB) avi->Colorimetry = XHDMIC_COLORIMETRY_ITU709;
    Vphy.HdmiTxRefClkHz = (u32)tmds;
    if (XVphy_SetHdmiTxParam(&Vphy, 0, XVPHY_CHANNEL_ID_CHA, XVIDC_PPC_2, modes[m].bpc, modes[m].cf) != XST_SUCCESS) {
        xil_printf("TX mode %d not possible: TMDS %d kHz, reference %d kHz, line rate %d Mb/s\r\n", (int)m, (int)(tmds / 1000),
            (int)(Vphy.HdmiTxRefClkHz / 1000), (int)(XVphy_GetLineRateHz(&Vphy, 0, XVPHY_CHANNEL_ID_CMN0) / 1000000));
        return;
    }
    IicQuiet();
    IdtLol(1);
    if (IDT_8T49N24x_SetClock(XPAR_IIC_0_BASEADDR, IDT_ADDR, IDT_8T49N24X_XTAL_FREQ, Vphy.HdmiTxRefClkHz, TRUE) != XST_SUCCESS) {
        xil_printf("clock chip not set\r\n");
        TxStatus |= 0x8u;
        return;
    }
    TxStatus &= ~0x8u;
    MetaPoll();
    SettleAt = Ticks + IDT_SETTLE_TICKS;
    Settling = 1;
    SettleTries = 0;
    TxStatus |= 0x4u;
    StartedAt = Ticks;
    Dumped = 0;
    xil_printf("TX mode %d, reference %d kHz\r\n", (int)m, (int)(Vphy.HdmiTxRefClkHz / 1000));
}

static void PtStop(void)
{
    if (!PtActive) return;
    PtActive = 0;
    Settling = 0;
    Xil_Out32(AUD_CFG, 0);
    XV_HdmiTxSs_Stop(&TxSs);
    StreamUp = 0;
    Applied = ~0u;
    xil_printf("loop-out off\r\n");
}

/* Copy the receiver's stream to the transmitter (as AMD's pass-through example does) and lock the clock chip to the
 * receiver's TMDS clock, which the Video PHY sends out on RX_REFCLK (FMC HDMI_REF_CLK -> 8T49N241 CLK0). */
static void PtStart(void)
{
    XV_HdmiRxSs *r = RxSsGet();
    XVidC_VideoStream *ts;
    const XVphy_PllType pll = XVphy_GetPllType(&Vphy, 0, XVPHY_DIR_RX, XVPHY_CHANNEL_ID_CH1);
    const u64 rxRate = XVphy_GetLineRateHz(&Vphy, 0, pll == XVPHY_PLL_TYPE_CPLL ? XVPHY_CHANNEL_ID_CH1 :
        (pll == XVPHY_PLL_TYPE_QPLL || pll == XVPHY_PLL_TYPE_QPLL0) ? XVPHY_CHANNEL_ID_CMN0 : XVPHY_CHANNEL_ID_CMN1);
    PtActive = 1;
    PtChanges = RxChanges();
    PtFailed = 0;
    Settling = 0;
    StreamUp = 0;
    Applied = 0;
    Xil_Out32(AUD_CFG, 0);
    XV_HdmiTxSs_Stop(&TxSs);
    SinkEdidOk = 0; SinkEdidTries = 0; SinkHbr = 0; SinkCodes = 0;
    ReadSinkAudio();
    MetaPoll();                                       /* the EDID read took a while */
    ts = XV_HdmiTxSs_GetVideoStream(&TxSs);
    *ts = *XV_HdmiRxSs_GetVideoStream(r);
    XV_HdmiTxSs_SetVideoIDCode(&TxSs, XV_HdmiRxSs_GetVideoIDCode(r));
    XV_HdmiTxSs_SetVideoStreamType(&TxSs, XV_HdmiRxSs_GetVideoStreamType(r));
    TxSs.HdmiTxPtr->Stream.IsHdmi20 = TRUE;
    if (rxRate / 1000000u > 3400u) {                  /* HDMI 2.0 rates: TMDS clock 1/40, scrambled */
        Vphy.HdmiTxRefClkHz = Vphy.HdmiRxRefClkHz * 4u;
        XV_HdmiTxSs_SetTmdsClockRatio(&TxSs, 1);
        XV_HdmiTxSs_SetVideoStreamScramblingFlag(&TxSs, TRUE);
    } else {
        Vphy.HdmiTxRefClkHz = Vphy.HdmiRxRefClkHz;
        XV_HdmiTxSs_SetTmdsClockRatio(&TxSs, 0);
        XV_HdmiTxSs_SetVideoStreamScramblingFlag(&TxSs, FALSE);
    }
    {   /* what XV_HdmiTx_SetStream does for a table mode, from the received stream (which may be a custom mode) */
        XV_HdmiTx *tx = TxSs.HdmiTxPtr;
        if (ts->ColorFormatId == XVIDC_CSF_YCRCB_422) ts->ColorDepth = XVIDC_BPC_12;   /* HDMI 4:2:2 is always 12 bit */
        tx->Stream.Video = *ts;
        XV_HdmiTx_SetPixelRate(tx);
        XV_HdmiTx_SetColorFormat(tx);
        XV_HdmiTx_SetColorDepth(tx);
        tx->Stream.TMDSClock = (u32)(rxRate / 10u);   /* TMDS character rate */
        tx->Stream.IsScrambled = tx->Stream.TMDSClock > 340000000u;
        tx->Stream.TMDSClockRatio = tx->Stream.IsScrambled;
        XV_HdmiTx_Scrambler(tx);                      /* also tells the sink (SCDC) */
        XV_HdmiTx_ClockRatio(tx);
    }
    if (XVphy_SetHdmiTxParam(&Vphy, 0, XVPHY_CHANNEL_ID_CHA, ts->PixPerClk, ts->ColorDepth, ts->ColorFormatId) != XST_SUCCESS) {
        xil_printf("loop-out not possible: RX reference %d kHz, line rate %d Mb/s\r\n", (int)(Vphy.HdmiRxRefClkHz / 1000), (int)(rxRate / 1000000));
        PtFailed = 1;
        PtActive = 0;
        return;
    }
    XVphy_Clkout1OBufTdsEnable(&Vphy, XVPHY_DIR_RX, TRUE);
    IicQuiet();
    IdtLol(1);
    if (IDT_8T49N24x_SetClock(XPAR_IIC_0_BASEADDR, IDT_ADDR, Vphy.HdmiRxRefClkHz, Vphy.HdmiTxRefClkHz, FALSE) != XST_SUCCESS) {
        xil_printf("loop-out: clock chip not set\r\n");
        TxStatus |= 0x8u;
        PtFailed = 1;
        PtActive = 0;
        return;
    }
    TxStatus &= ~0x8u;
    MetaPoll();                                       /* so did the clock chip */
    SettleAt = Ticks + 2u * IDT_SETTLE_TICKS;         /* locked mode: the DPLL has to catch the input as well */
    Settling = 1;
    SettleTries = 0;
    TxStatus |= 0x4u;
    StartedAt = Ticks;
    Dumped = 0;
    xil_printf("loop-out start %d x %d, RX reference %d kHz, TX reference %d kHz, line rate %d Mb/s\r\n", (int)ts->Timing.HActive,
        (int)ts->Timing.VActive, (int)(Vphy.HdmiRxRefClkHz / 1000), (int)(Vphy.HdmiTxRefClkHz / 1000), (int)(rxRate / 1000000));
}

int TxSetup(XIntc *intc)
{
    XV_HdmiTxSs_Config *c;
    XV_tpg_Config *g;
    IicQuiet();
    if (IDT_8T49N24x_Init(XPAR_IIC_0_BASEADDR, IDT_ADDR) != XST_SUCCESS) xil_printf("8T49N241 not found\r\n");
    else TxStatus |= 0x4u;
    c = XV_HdmiTxSs_LookupConfig(XPAR_XV_HDMITX_0_DEVICE_ID);
    if (!c || XV_HdmiTxSs_CfgInitialize(&TxSs, c, c->BaseAddress) != XST_SUCCESS) { xil_printf("TXSS init failed\r\n"); return 0; }
    g = XV_tpg_LookupConfig(XPAR_XV_TPG_0_DEVICE_ID);
    if (!g || XV_tpg_CfgInitialize(&Tpg, g, g->BaseAddress) != XST_SUCCESS) { xil_printf("TPG init failed\r\n"); return 0; }
    XIntc_Connect(intc, XPAR_INTC_0_V_HDMITXSS_0_VEC_ID, (XInterruptHandler)XV_HdmiTxSS_HdmiTxIntrHandler, &TxSs);
    XIntc_Enable(intc, XPAR_INTC_0_V_HDMITXSS_0_VEC_ID);
    XV_HdmiTxSs_SetCallback(&TxSs, XV_HDMITXSS_HANDLER_CONNECT, (void *)CbConnect, &TxSs);
    XV_HdmiTxSs_SetCallback(&TxSs, XV_HDMITXSS_HANDLER_VS, (void *)CbVsync, &TxSs);
    XV_HdmiTxSs_SetCallback(&TxSs, XV_HDMITXSS_HANDLER_STREAM_UP, (void *)CbStreamUp, &TxSs);
    XV_HdmiTxSs_SetCallback(&TxSs, XV_HDMITXSS_HANDLER_STREAM_DOWN, (void *)CbStreamDown, &TxSs);
    return 1;
}

void TxVphyCallbacks(void)
{
    XVphy_SetHdmiCallback(&Vphy, XVPHY_HDMI_HANDLER_TXINIT, (void *)CbTxInit, &Vphy);
    XVphy_SetHdmiCallback(&Vphy, XVPHY_HDMI_HANDLER_TXREADY, (void *)CbTxReady, &Vphy);
}

/* main loop, every 10 ms */
/* The retimer powers down while its HPD_SNK input is low; reg 09h bit 2 keeps it running (bits 1:0 = 100 kbps). */
static void Dp159Awake(void)
{
    u8 b[2] = { 0x09, 0x06 };
    XIic_Send(XPAR_IIC_0_BASEADDR, 0x5Eu, b, 2, XIIC_STOP);
}

/* TX_CTRL bit 9: loopback without hot plug. On the RK-FH1159 the TX connector's HPD never reaches the FPGA when our
 * own receiver is the sink, so the host can tell the transmitter to behave as if a sink were connected. */
static void ForceConnect(void)
{
    TxSs.HdmiTxPtr->Stream.IsConnected = TRUE;
    XV_HdmiTx_DdcDisable(TxSs.HdmiTxPtr);
    TxSs.IsStreamConnected = TRUE;
    Connected = 1;
    XVphy_IBufDsEnable(&Vphy, 0, XVPHY_DIR_TX, TRUE);
    Dp159Awake();
    Applied = ~0u;
    xil_printf("TX forced connected\r\n");
}

volatile u32 TxDebugOff;                        /* set from xsdb: transmitter off whatever the host asks */

void TxPoll(void)
{
    const u32 ctl = TxDebugOff ? 0u : Xil_In32(TX_CTRL);
    Want = ctl;
    const u32 ptWanted = !TxDebugOff && !(ctl & 1u) && !(ctl & 0x400u);
    if ((ctl & 0x200u) && !Connected && ((ctl & 1u) || ptWanted)) ForceConnect();
    if (ctl & 1u) {                                   /* test pattern: overrides the loop-out */
        PtStop();
        if (Connected && ctl != Applied) Start(ctl);
    } else {
        if (PtRestart) { PtRestart = 0; PtStop(); PtFailed = 0; }
        if (Applied != ~0u && (Applied & 1u)) { XV_HdmiTxSs_Stop(&TxSs); Xil_Out32(AUD_CFG, 0); StreamUp = 0; Applied = ~0u; Settling = 0; }
        if (ptWanted && Connected && RxUp()) {
            if ((!PtActive && !PtFailed) || RxChanges() != PtChanges) PtStart();
        } else {
            PtStop();
            PtFailed = 0;
            if (!PtActive) Applied = ctl & ~1u;
        }
        {   /* the stream callbacks set the same sound registers up and take them down: not in the middle of this */
            const u32 irq = IrqOff();
            if (PtActive && StreamUp) {               /* audio clock regeneration follows the source's N/CTS */
                XV_HdmiRxSs *r = RxSsGet();
                const u32 key = RxAudKey();
                Xil_Out32(AUD_N, XV_HdmiRx_GetAcrN(r->HdmiRxPtr));
                Xil_Out32(AUD_CTS, XV_HdmiRx_GetAcrCts(r->HdmiRxPtr));
                if (key == PtAudKey) {                /* a new format must hold for 50 ms before the sound is switched */
                    PtAudSeen = 0;
                    if (PtAudNew != PtAudKey) {       /* it did not: back to the format the transmitter is set for, sound on again */
                        PtAudNew = PtAudKey;
                        if (!PtAudMuted) {
                            XV_HdmiTxSs_AudioMute(&TxSs, FALSE);
                            Xil_Out32(AUD_CFG, 0x1u | PT_VIDEO | PT_AUDIO);
                        }
                    }
                }
                else if (key != PtAudNew) {           /* silent at once: never play one format as another */
                    PtAudNew = key; PtAudSeen = 0;
                    Xil_Out32(AUD_CFG, 0x1u | PT_VIDEO);
                    XV_HdmiTxSs_AudioMute(&TxSs, TRUE);
                }
                else if (++PtAudSeen >= 5u) PtAudio(&TxSs);
            }
            IrqOn(irq);
        }
    }
    if (Settling && (s32)(Ticks - SettleAt) >= 0) {   /* reference clock final: "ready" for the Video PHY, one clean start */
        if (IdtLol(0) || ++SettleTries >= 5u) {       /* (the chip did not take it: try again on the next pass) */
            Settling = 0;
            XVphy_ClkDetFreqReset(&Vphy, 0, XVPHY_DIR_TX);
            xil_printf("TX reference settled, start%s\r\n", SettleTries >= 5u ? " (clock chip did not answer)" : "");
        }
    }
    if (StreamUp && NeedRetimer) {                    /* the retimer follows the line rate once the stream runs */
        NeedRetimer = 0;
        i2c_dp159(&Vphy, 0, LineRate);
        if (Want & 0x200u) Dp159Awake();
        XVphy_Clkout1OBufTdsEnable(&Vphy, XVPHY_DIR_TX, TRUE);
    }
    if (PtActive && StreamUp && !NeedRetimer && !SinkEdidOk && SinkEdidTries < 12u &&
        (Ticks & (SinkEdidTries < 4u ? 63u : 255u)) == 0u) {
        ReadSinkAudio();                              /* the first tries can come before the sink's DDC answers: 3 more in */
        MetaPoll();                                   /* the first 2 s, then every 2.6 s up to about 22 s (AV receivers) */
        if (SinkEdidOk) {
            const u32 irq = IrqOff();
            if (PtActive && StreamUp && PtAudMuted) PtAudio(&TxSs);
            IrqOn(irq);
        }
    }
    Ticks++;
    if ((Applied & 1u) && Applied != ~0u && !StreamUp && !Dumped && Ticks - StartedAt > 300u) {   /* 3 s without a stream */
        Dumped = 1;
        xil_printf("--- TX not up after 3 s\r\n");
        XVphy_LogDisplay(&Vphy);
        XVphy_HdmiDebugInfo(&Vphy, 0, XVPHY_CHANNEL_ID_CH1);
        XV_HdmiTxSs_ReportInfo(&TxSs);
    }
    (void)Seen;
    TxStatus = (TxStatus & 0xCu) | (Connected ? 1u : 0u) | (StreamUp ? 2u : 0u) | ((PtActive ? 0xEu : (Applied & 0xFu)) << 4) | ((Ups & 0xFFu) << 8);
}
