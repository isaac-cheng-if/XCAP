// XCAP capture driver (KMDF): streams AXI-Stream frames from a Xilinx XDMA C2H
// engine into a ring of frame slots in host memory and maps that ring, read
// only, into the capturing process.
//
// The engine runs a cyclic descriptor list, so no request is issued per frame.
// The memory belongs to the driver: if the process dies or the engine will not
// stop, the pages are kept instead of being handed back while DMA may write them.
#include <ntifs.h>
#include <wdf.h>
#include <initguid.h>
#include <wdmguid.h>
#include "xcap_ioctl.h"

#define XTAG 'pacX'

// Exported by the kernel, not declared in the WDK headers. While held, the process cannot finish exiting.
NTKERNELAPI NTSTATUS PsAcquireProcessExitSynchronization(_In_ PEPROCESS Process);
NTKERNELAPI VOID PsReleaseProcessExitSynchronization(_In_ PEPROCESS Process);

// ---- XDMA register map (PG195) ----
#define C2H(r)            (0x1000u + (r))
#define C2HA(r)           (0x1100u + (r))        // second C2H engine: audio
#define CH_ID             0x00u
#define CH_CTRL           0x04u
#define CH_CTRL_W1S       0x08u
#define CH_CTRL_W1C       0x0Cu
#define CH_STATUS         0x40u
#define CH_STATUS_RC      0x44u
#define CH_DESC_COUNT     0x48u
#define CH_POLL_LO        0x88u
#define CH_POLL_HI        0x8Cu
#define CH_IE             0x90u
#define C2H_SGDMA(r)      (0x5000u + (r))
#define C2HA_SGDMA(r)     (0x5100u + (r))
#define SG_DESC_LO        0x80u
#define SG_DESC_HI        0x84u
#define SG_DESC_ADJ       0x88u
#define IRQ(r)            (0x2000u + (r))
#define IRQ_USR_EN_W1C    0x0Cu
#define IRQ_CH_EN         0x10u
#define IRQ_CH_EN_W1S     0x14u
#define IRQ_CH_EN_W1C     0x18u
#define IRQ_USR_VEC0      0x80u
#define IRQ_CH_VEC0       0xA0u
#define CFG(r)            (0x3000u + (r))

#define CTRL_RUN          (1u << 0)
#define CTRL_IE_STOPPED   (1u << 1)
#define CTRL_IE_COMPLETED (1u << 2)
#define CTRL_IE_ALIGN     (1u << 3)
#define CTRL_IE_MAGIC     (1u << 4)
#define CTRL_IE_INVLEN    (1u << 5)
#define CTRL_IE_RDERR     (0x1Fu << 9)
#define CTRL_IE_DESCERR   (0x1Fu << 19)
#define CTRL_POLL_WB      (1u << 26)
#define IE_ERRORS         (CTRL_IE_ALIGN | CTRL_IE_MAGIC | CTRL_IE_INVLEN | CTRL_IE_RDERR | CTRL_IE_DESCERR)
#define ST_BUSY           (1u << 0)
#define ST_ERRORS         IE_ERRORS
#define ST_DONE           (CTRL_IE_STOPPED | CTRL_IE_COMPLETED)

#define DESC_MAGIC        0xAD4B0000u
#define DESC_COMPLETED    0x2u
#define WB_MAGIC          0x52B40000u
#define WB_EOP            0x1u
#define C2H_IRQ_BIT       0x2u          // one H2C channel comes first
#define C2HA_IRQ_BIT      0x4u

#pragma pack(push, 1)
typedef struct { ULONG control, length, src_lo, src_hi, dst_lo, dst_hi, next_lo, next_hi; } XDESC;
typedef struct { volatile ULONG status, length; } XRESULT;
#pragma pack(pop)
C_ASSERT(sizeof(XDESC) == 32);
C_ASSERT(sizeof(xcap_ctl) <= XCAP_CTL_BYTES);
C_ASSERT(XCAP_MAX_BANDS <= XCAP_MAX_SLICES);

#define DESCS_PER_BLOCK   2048u          // 64 KB of descriptors + 16 KB of results
#define BLOCK_DESC_BYTES  (DESCS_PER_BLOCK * sizeof(XDESC))
#define BLOCK_BYTES       (BLOCK_DESC_BYTES + DESCS_PER_BLOCK * sizeof(XRESULT))
#define MAX_BLOCKS        128u
#define SG_CHUNK          (2u * 1024 * 1024)
#define MAX_SGL           4096u
#define MAX_DEVICES       8u
#define STATE_STREAMING   1u
#define STATE_STOPPED     2u
#define STATE_ERROR       3u

typedef struct {
    PMDL mdl;
    PVOID user;
} SLOT;

typedef struct {
    WDFDEVICE device;
    WDFDMAENABLER enabler;
    PDMA_ADAPTER adapter;               // owned by the enabler
    WDFINTERRUPT interrupt;
    PUCHAR bar_user, bar_dma;
    SIZE_T bar_user_len, bar_dma_len;
    BUS_INTERFACE_STANDARD bus;
    BOOLEAN have_bus;
    ULONG c2h_id;

    WDFWAITLOCK lock;                   // everything below unless noted
    BOOLEAN d0;                         // powered: the BARs may be touched
    BOOLEAN hw_ready;                   // d0 and the user registers answer
    BOOLEAN streaming;                  // also read by the DPC
    BOOLEAN has_audio, audio_on;        // audio_on is also read by the DPC
    PKEVENT audio_event;
    WDFCOMMONBUFFER aud_cb, audd_cb; PMDL aud_mdl; PVOID aud_user;
    BOOLEAN stuck;                      // engine would not go idle: never free its memory
    BOOLEAN orphaned;                   // views were left in a process that was exiting: memory is kept until the device is released
    BOOLEAN mem_valid;
    WDFFILEOBJECT owner;
    PEPROCESS volatile owner_process;   // the process the views are mapped into (referenced); also looked at by the process exit callback
    PKEVENT event;                      // read by the DPC while streaming
    ULONG slots, frame_bytes, slices, ndesc, descs_per_frame, contiguous;
    SLOT slot[XCAP_MAX_SLOTS];
    PSCATTER_GATHER_LIST *sgl; ULONG nsgl;
    WDFCOMMONBUFFER block[MAX_BLOCKS]; ULONG nblocks;
    WDFCOMMONBUFFER ctl_cb; xcap_ctl *ctl; PMDL ctl_mdl; PVOID ctl_user;
    volatile ULONG irq_count;
    ULONG64 irq_total, start_total;
    // DPC state
    ULONG dpc_seen;                     // 24-bit hardware count at the previous DPC
    ULONG dpc_pos;                      // position inside the ring (descriptors)
    ULONG aud_seen;                     // 24-bit audio packet count at the previous DPC
} DEV;
WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DEV, DevCtx)

DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD EvtDeviceAdd;
EVT_WDF_DEVICE_PREPARE_HARDWARE EvtPrepare;
EVT_WDF_DEVICE_RELEASE_HARDWARE EvtRelease;
EVT_WDF_DEVICE_D0_ENTRY EvtD0Entry;
EVT_WDF_DEVICE_D0_EXIT EvtD0Exit;
EVT_WDF_DEVICE_CONTEXT_CLEANUP EvtDeviceCleanup;
EVT_WDF_INTERRUPT_ISR EvtIsr;
EVT_WDF_INTERRUPT_DPC EvtDpc;
EVT_WDF_IO_IN_CALLER_CONTEXT EvtInCaller;
EVT_WDF_FILE_CLEANUP EvtFileCleanup;
EVT_WDF_DRIVER_UNLOAD EvtDriverUnload;
DRIVER_LIST_CONTROL SgReady;
VOID EvtProcessNotify(PEPROCESS process, HANDLE pid, PPS_CREATE_NOTIFY_INFO info);

static WDFWAITLOCK g_lock;              // g_dev; taken before a device lock, never after
static DEV *g_dev[MAX_DEVICES];
static BOOLEAN g_notify;                // EvtProcessNotify is registered

static ULONG Rd(PUCHAR bar, ULONG off) { return READ_REGISTER_ULONG((PULONG)(bar + off)); }
static VOID  Wr(PUCHAR bar, ULONG off, ULONG v) { WRITE_REGISTER_ULONG((PULONG)(bar + off), v); }

static VOID SleepUs(LONGLONG us)
{
    LARGE_INTEGER t; t.QuadPart = -10 * us;
    KeDelayExecutionThread(KernelMode, FALSE, &t);
}

// ---------------------------------------------------------------- memory ----

typedef struct { KEVENT done; PSCATTER_GATHER_LIST sg; } SGWAIT;

VOID SgReady(PDEVICE_OBJECT dev, PIRP irp, PSCATTER_GATHER_LIST sg, PVOID ctx)
{
    SGWAIT *w = (SGWAIT *)ctx;
    UNREFERENCED_PARAMETER(dev); UNREFERENCED_PARAMETER(irp);
    w->sg = sg;
    KeSetEvent(&w->done, 0, FALSE);
}

static VOID FreeMemory(DEV *d)
{
    ULONG i;
    if (d->stuck || d->orphaned) return; // quarantined: the engine may still write, or a dying process still has the views
    for (i = 0; i < d->nsgl; i++) {
        KIRQL irql;
        KeRaiseIrql(DISPATCH_LEVEL, &irql);
        d->adapter->DmaOperations->PutScatterGatherList(d->adapter, d->sgl[i], FALSE);
        KeLowerIrql(irql);
    }
    d->nsgl = 0;
    if (d->sgl) { ExFreePoolWithTag(d->sgl, XTAG); d->sgl = NULL; }
    for (i = 0; i < d->nblocks; i++) { WdfObjectDelete(d->block[i]); d->block[i] = NULL; }
    d->nblocks = 0;
    for (i = 0; i < XCAP_MAX_SLOTS; i++) if (d->slot[i].mdl) {
        MmFreePagesFromMdl(d->slot[i].mdl);
        ExFreePool(d->slot[i].mdl);
        d->slot[i].mdl = NULL;
    }
    if (d->aud_mdl) { IoFreeMdl(d->aud_mdl); d->aud_mdl = NULL; }
    if (d->aud_cb) { WdfObjectDelete(d->aud_cb); d->aud_cb = NULL; }
    if (d->audd_cb) { WdfObjectDelete(d->audd_cb); d->audd_cb = NULL; }
    if (d->ctl_mdl) { IoFreeMdl(d->ctl_mdl); d->ctl_mdl = NULL; }
    if (d->ctl_cb) { WdfObjectDelete(d->ctl_cb); d->ctl_cb = NULL; d->ctl = NULL; }
    d->mem_valid = FALSE;
}

static PMDL AllocSlot(SIZE_T bytes, PULONG contiguous)
{
    static const ULONG chunk[] = { 2u << 20, 64u << 10, 0 };
    PHYSICAL_ADDRESS lo, hi, skip;
    ULONG i;
    lo.QuadPart = 0; hi.QuadPart = -1;
    for (i = 0; i < ARRAYSIZE(chunk); i++) {
        SIZE_T want = chunk[i] ? (bytes + chunk[i] - 1) & ~((SIZE_T)chunk[i] - 1) : bytes;
        ULONG flags = MM_ALLOCATE_FULLY_REQUIRED | MM_ALLOCATE_FAST_LARGE_PAGES;
        PMDL m;
        skip.QuadPart = chunk[i];
        if (chunk[i]) flags |= MM_ALLOCATE_REQUIRE_CONTIGUOUS_CHUNKS;
        if (chunk[i] != (2u << 20)) flags &= ~MM_ALLOCATE_FAST_LARGE_PAGES;
        m = MmAllocatePagesForMdlEx(lo, hi, skip, want, MmCached, flags);
        if (!m) continue;
        if (MmGetMdlByteCount(m) >= bytes) {
            ULONG c = chunk[i] ? chunk[i] : PAGE_SIZE;
            if (c < *contiguous) *contiguous = c;
            return m;
        }
        MmFreePagesFromMdl(m);
        ExFreePool(m);
    }
    return NULL;
}

static XDESC *DescAt(DEV *d, ULONG i)
{
    return (XDESC *)WdfCommonBufferGetAlignedVirtualAddress(d->block[i / DESCS_PER_BLOCK]) + i % DESCS_PER_BLOCK;
}
static ULONG64 DescBus(DEV *d, ULONG i)
{
    return WdfCommonBufferGetAlignedLogicalAddress(d->block[i / DESCS_PER_BLOCK]).QuadPart + (ULONG64)(i % DESCS_PER_BLOCK) * sizeof(XDESC);
}
static XRESULT *ResultAt(DEV *d, ULONG i)
{
    PUCHAR b = (PUCHAR)WdfCommonBufferGetAlignedVirtualAddress(d->block[i / DESCS_PER_BLOCK]);
    return (XRESULT *)(b + BLOCK_DESC_BYTES) + i % DESCS_PER_BLOCK;
}
static ULONG64 ResultBus(DEV *d, ULONG i)
{
    return WdfCommonBufferGetAlignedLogicalAddress(d->block[i / DESCS_PER_BLOCK]).QuadPart + BLOCK_DESC_BYTES + (ULONG64)(i % DESCS_PER_BLOCK) * sizeof(XRESULT);
}

static NTSTATUS AddDesc(DEV *d, ULONG64 dst, ULONG len, BOOLEAN completed)
{
    ULONG i = d->ndesc;
    XDESC *x;
    ULONG64 res;
    if (i / DESCS_PER_BLOCK >= d->nblocks) {
        NTSTATUS st;
        if (d->nblocks == MAX_BLOCKS) return STATUS_INSUFFICIENT_RESOURCES;
        st = WdfCommonBufferCreate(d->enabler, BLOCK_BYTES, WDF_NO_OBJECT_ATTRIBUTES, &d->block[d->nblocks]);
        if (!NT_SUCCESS(st)) return st;
        RtlZeroMemory(WdfCommonBufferGetAlignedVirtualAddress(d->block[d->nblocks]), BLOCK_BYTES);
        d->nblocks++;
    }
    x = DescAt(d, i);
    res = ResultBus(d, i);
    x->control = DESC_MAGIC | (completed ? DESC_COMPLETED : 0);
    x->length = len;
    x->src_lo = (ULONG)res; x->src_hi = (ULONG)(res >> 32);     // C2H stream: result write-back address
    x->dst_lo = (ULONG)dst; x->dst_hi = (ULONG)(dst >> 32);
    d->ndesc++;
    return STATUS_SUCCESS;
}

// Walks the scatter/gather lists of one slot and cuts them at progress boundaries.
static NTSTATUS BuildSlot(DEV *d, ULONG s, const xcap_start_in *in)
{
    ULONG64 bus_next = 0, bus_start = 0;
    ULONG run = 0, pos = 0, slice = 0, off;
    ULONG next_cut = XCAP_HDR_BYTES + min(in->slice_bytes, in->data_bytes);
    NTSTATUS st;

    for (off = 0; off < d->frame_bytes; off += SG_CHUNK) {
        ULONG len = min(SG_CHUNK, d->frame_bytes - off), e;
        SGWAIT w; KIRQL irql;
        KeInitializeEvent(&w.done, NotificationEvent, FALSE); w.sg = NULL;
        KeRaiseIrql(DISPATCH_LEVEL, &irql);
        st = d->adapter->DmaOperations->GetScatterGatherList(d->adapter, WdfDeviceWdmGetDeviceObject(d->device), d->slot[s].mdl,
            (PUCHAR)MmGetMdlVirtualAddress(d->slot[s].mdl) + off, len, SgReady, &w, FALSE);
        KeLowerIrql(irql);
        if (!NT_SUCCESS(st)) return st;
        KeWaitForSingleObject(&w.done, Executive, KernelMode, FALSE, NULL);
        if (d->nsgl == MAX_SGL) {
            KeRaiseIrql(DISPATCH_LEVEL, &irql);
            d->adapter->DmaOperations->PutScatterGatherList(d->adapter, w.sg, FALSE);
            KeLowerIrql(irql);
            return STATUS_INSUFFICIENT_RESOURCES;
        }
        d->sgl[d->nsgl++] = w.sg;
        for (e = 0; e < w.sg->NumberOfElements; e++) {
            ULONG64 a = w.sg->Elements[e].Address.QuadPart;
            ULONG n = w.sg->Elements[e].Length;
            if (run && a != bus_next) {                 // not contiguous: close the current run
                st = AddDesc(d, bus_start, run, FALSE);
                if (!NT_SUCCESS(st)) return st;
                run = 0;
            }
            while (n) {
                ULONG end = (slice + 1 == d->slices) ? d->frame_bytes : next_cut;
                ULONG take = min(n, end - pos);
                if (!run) bus_start = a;
                run += take; a += take; n -= take; pos += take;
                if (pos == end) {
                    st = AddDesc(d, bus_start, run, TRUE);
                    if (!NT_SUCCESS(st)) return st;
                    run = 0;
                    d->ctl->slice_end[s][slice] = d->ndesc;
                    slice++;
                    next_cut += in->slice_bytes;
                }
            }
            bus_next = a;
        }
    }
    return (pos == d->frame_bytes && run == 0 && slice == d->slices) ? STATUS_SUCCESS : STATUS_INTERNAL_ERROR;
}

// One descriptor per fixed-size audio packet, linked into a ring. Descriptors are
// followed by the engine's 8-byte results in the same block.
#define AUD_DESC_BYTES  (XCAP_AUD_RING * sizeof(XDESC))
static NTSTATUS AllocAudio(DEV *d)
{
    NTSTATUS st;
    ULONG i;
    XDESC *x;
    ULONG64 ring, desc;
    st = WdfCommonBufferCreate(d->enabler, XCAP_AUD_RING * XCAP_AUD_PACKET, WDF_NO_OBJECT_ATTRIBUTES, &d->aud_cb);
    if (!NT_SUCCESS(st)) return st;
    st = WdfCommonBufferCreate(d->enabler, AUD_DESC_BYTES + XCAP_AUD_RING * sizeof(XRESULT), WDF_NO_OBJECT_ATTRIBUTES, &d->audd_cb);
    if (!NT_SUCCESS(st)) return st;
    RtlZeroMemory(WdfCommonBufferGetAlignedVirtualAddress(d->aud_cb), XCAP_AUD_RING * XCAP_AUD_PACKET);
    d->aud_mdl = IoAllocateMdl(WdfCommonBufferGetAlignedVirtualAddress(d->aud_cb), XCAP_AUD_RING * XCAP_AUD_PACKET, FALSE, FALSE, NULL);
    if (!d->aud_mdl) return STATUS_INSUFFICIENT_RESOURCES;
    MmBuildMdlForNonPagedPool(d->aud_mdl);
    x = (XDESC *)WdfCommonBufferGetAlignedVirtualAddress(d->audd_cb);
    RtlZeroMemory(x, AUD_DESC_BYTES + XCAP_AUD_RING * sizeof(XRESULT));
    ring = WdfCommonBufferGetAlignedLogicalAddress(d->aud_cb).QuadPart;
    desc = WdfCommonBufferGetAlignedLogicalAddress(d->audd_cb).QuadPart;
    for (i = 0; i < XCAP_AUD_RING; i++) {
        ULONG n = (i + 1) % XCAP_AUD_RING;
        ULONG64 dst = ring + (ULONG64)i * XCAP_AUD_PACKET, res = desc + AUD_DESC_BYTES + (ULONG64)i * sizeof(XRESULT), nx = desc + (ULONG64)n * sizeof(XDESC);
        ULONG in_page = (ULONG)((PAGE_SIZE - (nx & (PAGE_SIZE - 1))) / sizeof(XDESC)) - 1;
        x[i].control = DESC_MAGIC | DESC_COMPLETED | min(min(in_page, 15u), XCAP_AUD_RING - 1 - n) << 8;
        x[i].length = XCAP_AUD_PACKET;
        x[i].src_lo = (ULONG)res; x[i].src_hi = (ULONG)(res >> 32);
        x[i].dst_lo = (ULONG)dst; x[i].dst_hi = (ULONG)(dst >> 32);
        x[i].next_lo = (ULONG)nx; x[i].next_hi = (ULONG)(nx >> 32);
    }
    return STATUS_SUCCESS;
}

static NTSTATUS AllocAll(DEV *d, const xcap_start_in *in)
{
    NTSTATUS st;
    ULONG s, i;

    st = WdfCommonBufferCreate(d->enabler, XCAP_CTL_BYTES, WDF_NO_OBJECT_ATTRIBUTES, &d->ctl_cb);
    if (!NT_SUCCESS(st)) return st;
    d->mem_valid = TRUE;
    d->ctl = (xcap_ctl *)WdfCommonBufferGetAlignedVirtualAddress(d->ctl_cb);
    RtlZeroMemory(d->ctl, XCAP_CTL_BYTES);
    d->ctl_mdl = IoAllocateMdl(d->ctl, XCAP_CTL_BYTES, FALSE, FALSE, NULL);
    if (!d->ctl_mdl) return STATUS_INSUFFICIENT_RESOURCES;
    MmBuildMdlForNonPagedPool(d->ctl_mdl);

    d->sgl = (PSCATTER_GATHER_LIST *)ExAllocatePool2(POOL_FLAG_NON_PAGED, MAX_SGL * sizeof(*d->sgl), XTAG);
    if (!d->sgl) return STATUS_INSUFFICIENT_RESOURCES;

    if (in->audio) {
        st = AllocAudio(d);
        if (!NT_SUCCESS(st)) return st;
    }
    d->contiguous = 2u << 20;
    d->ndesc = 0;
    for (s = 0; s < d->slots; s++) {
        d->slot[s].mdl = AllocSlot(d->frame_bytes, &d->contiguous);
        if (!d->slot[s].mdl) return STATUS_INSUFFICIENT_RESOURCES;
        st = BuildSlot(d, s, in);
        if (!NT_SUCCESS(st)) return st;
    }
    // link the list into a ring; tell the engine how many descriptors follow contiguously (inside one 4 KB page)
    for (i = 0; i < d->ndesc; i++) {
        XDESC *x = DescAt(d, i);
        ULONG n = (i + 1 == d->ndesc) ? 0 : i + 1;
        ULONG64 bus = DescBus(d, n);
        ULONG in_page = (ULONG)((PAGE_SIZE - (bus & (PAGE_SIZE - 1))) / sizeof(XDESC)) - 1;
        ULONG in_block = DESCS_PER_BLOCK - 1 - (n % DESCS_PER_BLOCK);
        ULONG adj = min(min(in_page, in_block), min(15u, d->ndesc - 1 - n));
        x->control |= adj << 8;
        x->next_lo = (ULONG)bus; x->next_hi = (ULONG)(bus >> 32);
    }
    return STATUS_SUCCESS;
}

static VOID UnmapViews(DEV *d)          // in the address space of the owner
{
    ULONG s;
    for (s = 0; s < XCAP_MAX_SLOTS; s++) if (d->slot[s].user) { MmUnmapLockedPages(d->slot[s].user, d->slot[s].mdl); d->slot[s].user = NULL; }
    if (d->aud_user) { MmUnmapLockedPages(d->aud_user, d->aud_mdl); d->aud_user = NULL; }
    if (d->ctl_user) { MmUnmapLockedPages(d->ctl_user, d->ctl_mdl); d->ctl_user = NULL; }
}

// Takes the views out of the owner's address space. The file handle can live on in another process
// (DuplicateHandle, inheritance), so this may run outside the owner; an address space that is being
// deleted must not be touched. FALSE: the owner is exiting right now and nothing was changed.
static BOOLEAN UnmapUser(DEV *d)
{
    PEPROCESS p = d->owner_process;
    KAPC_STATE apc;
    if (!p) return TRUE;
    if (PsGetCurrentProcess() == p) UnmapViews(d);    // also the owner's own exit: handles are closed and the exit callback runs before its address space is deleted
    else {
        if (!NT_SUCCESS(PsAcquireProcessExitSynchronization(p))) return FALSE;
        if (PsGetProcessExitStatus(p) != STATUS_PENDING) { PsReleaseProcessExitSynchronization(p); return FALSE; }
        KeStackAttachProcess(p, &apc);
        UnmapViews(d);
        KeUnstackDetachProcess(&apc);
        PsReleaseProcessExitSynchronization(p);
    }
    d->owner_process = NULL;
    ObDereferenceObject(p);
    return TRUE;
}

// The owner's address space is going away with the views still in it and they cannot be reached from here.
// The memory manager removes them together with the address space; the pages are not given back before
// the device is released.
static VOID AbandonViews(DEV *d)
{
    PEPROCESS p = d->owner_process;
    ULONG s;
    for (s = 0; s < XCAP_MAX_SLOTS; s++) d->slot[s].user = NULL;
    d->aud_user = NULL; d->ctl_user = NULL;
    d->owner_process = NULL;
    if (p) ObDereferenceObject(p);
    if (d->mem_valid) d->orphaned = TRUE;
    d->owner = NULL;
}

static PVOID MapUser(PMDL mdl)
{
    PVOID p = NULL;
    __try {
        p = MmMapLockedPagesSpecifyCache(mdl, UserMode, MmCached, NULL, FALSE, NormalPagePriority | MdlMappingNoExecute | MdlMappingNoWrite);
    } __except (EXCEPTION_EXECUTE_HANDLER) { p = NULL; }
    return p;
}

static NTSTATUS MapAll(DEV *d)
{
    ULONG s;
    d->owner_process = PsGetCurrentProcess();
    ObReferenceObject(d->owner_process);
    d->ctl_user = MapUser(d->ctl_mdl);
    if (!d->ctl_user) return STATUS_INSUFFICIENT_RESOURCES;
    if (d->aud_mdl) {
        d->aud_user = MapUser(d->aud_mdl);
        if (!d->aud_user) return STATUS_INSUFFICIENT_RESOURCES;
    }
    for (s = 0; s < d->slots; s++) {
        d->slot[s].user = MapUser(d->slot[s].mdl);
        if (!d->slot[s].user) return STATUS_INSUFFICIENT_RESOURCES;
    }
    return STATUS_SUCCESS;
}

// ---------------------------------------------------------------- engine ----

static BOOLEAN EngineIdle(DEV *d, ULONG status_reg, ULONG flush)
{
    // Run was cleared. An idle stream leaves the engine waiting inside a
    // descriptor; one short packet at a time (flush != 0) lets it finish and stop.
    ULONG i;
    for (i = 0; i < 24; i++) {
        ULONG st = Rd(d->bar_dma, status_reg);
        if (st == 0xFFFFFFFFu) return TRUE;          // device is gone, nothing can DMA any more
        if (!(st & ST_BUSY)) return TRUE;
        if (i >= 4 && flush && d->hw_ready) Wr(d->bar_user, XCAP_REG_FLUSH, flush);
        SleepUs(200);
    }
    return FALSE;
}

static VOID StopEngine(DEV *d)
{
    ULONG i;
    if (!d->streaming) return;
    if (d->d0) {
        // The user registers (AXI-Lite) and the DMA block fail independently. Ask the user side once more;
        // whatever it says, the engines are stopped through the DMA BAR.
        d->hw_ready = (BOOLEAN)(Rd(d->bar_user, XCAP_REG_ID) == XCAP_ID_MAGIC);
        if (d->hw_ready) {
            Wr(d->bar_user, XCAP_REG_CTRL, Rd(d->bar_user, XCAP_REG_CTRL) & ~(XCAP_CTRL_STREAM_EN | XCAP_CTRL_AUDIO_EN));
            for (i = 0; i < 200; i++) {              // the framer always finishes its frame
                if (!(Rd(d->bar_user, XCAP_REG_STATUS) & XCAP_STATUS_BUSY)) break;
                SleepUs(1000);
            }
            SleepUs(500);
        }
        Wr(d->bar_dma, IRQ(IRQ_CH_EN_W1C), C2H_IRQ_BIT | C2HA_IRQ_BIT);
        Wr(d->bar_dma, C2H(CH_CTRL_W1C), CTRL_RUN);
        if (d->audio_on) Wr(d->bar_dma, C2HA(CH_CTRL_W1C), CTRL_RUN);
        Rd(d->bar_dma, C2H(CH_STATUS));
    }
    WdfInterruptAcquireLock(d->interrupt);
    d->streaming = FALSE;
    WdfInterruptReleaseLock(d->interrupt);
    KeFlushQueuedDpcs();
    if (d->d0) {
        // a DPC that was already running has enabled the interrupts again
        Wr(d->bar_dma, IRQ(IRQ_CH_EN_W1C), C2H_IRQ_BIT | C2HA_IRQ_BIT);
        // The ring may be freed only when the engine is idle or the DMA BAR reads all ones (card gone).
        if (!EngineIdle(d, C2H(CH_STATUS), 1)) d->stuck = TRUE;
        if (d->audio_on) {
            if (!EngineIdle(d, C2HA(CH_STATUS), 2)) d->stuck = TRUE;
            Wr(d->bar_dma, C2HA(CH_CTRL), 0);
            Rd(d->bar_dma, C2HA(CH_STATUS_RC));
        }
        Wr(d->bar_dma, C2H(CH_CTRL), 0);
        Rd(d->bar_dma, C2H(CH_STATUS_RC));
    }
    d->audio_on = FALSE;
    if (d->ctl) d->ctl->state = STATE_STOPPED;
    if (d->event) { KeSetEvent(d->event, 0, FALSE); ObDereferenceObject(d->event); d->event = NULL; }
    if (d->audio_event) { KeSetEvent(d->audio_event, 0, FALSE); ObDereferenceObject(d->audio_event); d->audio_event = NULL; }
}

// A quarantined ring is given back once both engines are seen stopped. Lock held.
static VOID ReleaseQuarantine(DEV *d)
{
    BOOLEAN idle;
    if (!d->stuck || !d->d0 || d->streaming) return;
    if (d->hw_ready) Wr(d->bar_user, XCAP_REG_CTRL, Rd(d->bar_user, XCAP_REG_CTRL) & ~(XCAP_CTRL_STREAM_EN | XCAP_CTRL_AUDIO_EN));
    Wr(d->bar_dma, C2H(CH_CTRL_W1C), CTRL_RUN);
    if (d->has_audio) Wr(d->bar_dma, C2HA(CH_CTRL_W1C), CTRL_RUN);
    idle = EngineIdle(d, C2H(CH_STATUS), 1);         // a flush packet lands in the quarantined ring, which is still ours
    if (d->has_audio && !EngineIdle(d, C2HA(CH_STATUS), 2)) idle = FALSE;
    if (!idle) return;
    d->stuck = FALSE;
    if (d->mem_valid && !d->owner) FreeMemory(d);
}

// FALSE: the engine is stopped, but the views are in a process that is exiting right now and could not
// be removed from this one; views, memory and owner are as they were.
static BOOLEAN StopAll(DEV *d)
{
    StopEngine(d);
    if (!UnmapUser(d)) return FALSE;
    if (d->mem_valid) FreeMemory(d);
    d->owner = NULL;
    return TRUE;
}

static NTSTATUS StartEngine(DEV *d, const xcap_start_in *in)
{
    ULONG64 first = DescBus(d, 0);
    ULONG64 wb = WdfCommonBufferGetAlignedLogicalAddress(d->ctl_cb).QuadPart + FIELD_OFFSET(xcap_ctl, hw_desc_count);
    ULONG ctrl = Rd(d->bar_user, XCAP_REG_CTRL) & ~(XCAP_CTRL_STREAM_EN | XCAP_CTRL_SRC_HDMI | XCAP_CTRL_TPG_EN | XCAP_CTRL_AUDIO_EN);
    ULONG pad, adj;

    // An engine that is busy here holds descriptors from an earlier life (this driver stops it before it
    // frees a ring). Whatever they point to is not ours any more: no flush packet, only wait.
    if (Rd(d->bar_dma, C2H(CH_STATUS)) & ST_BUSY) {
        Wr(d->bar_dma, C2H(CH_CTRL_W1C), CTRL_RUN);
        if (!EngineIdle(d, C2H(CH_STATUS), 0)) return STATUS_DEVICE_BUSY;
    }
    if (in->audio && (Rd(d->bar_dma, C2HA(CH_STATUS)) & ST_BUSY)) {
        Wr(d->bar_dma, C2HA(CH_CTRL_W1C), CTRL_RUN);
        if (!EngineIdle(d, C2HA(CH_STATUS), 0)) return STATUS_DEVICE_BUSY;
    }
    Wr(d->bar_user, XCAP_REG_CTRL, ctrl);
    // Streams are off now: drop any beat the framers still hold from an earlier run, so it cannot lead this one.
    if (Rd(d->bar_user, XCAP_REG_VERSION) >= 0x00030301u) Wr(d->bar_user, XCAP_REG_FLUSH, XCAP_FLUSH_ABORT_VIDEO | XCAP_FLUSH_ABORT_AUDIO);
    pad = ((in->data_bytes + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1)) - in->data_bytes;
    Wr(d->bar_user, XCAP_REG_DATA_BEATS, in->data_bytes / 16);
    Wr(d->bar_user, XCAP_REG_PAD_BEATS, pad / 16);
    Wr(d->bar_user, XCAP_REG_GEOM, in->geom);
    Wr(d->bar_user, XCAP_REG_STRIDE, in->stride);
    Wr(d->bar_user, XCAP_REG_PIXFMT, in->pixfmt);
    Wr(d->bar_user, XCAP_REG_SLICE_BEATS, in->slice_bytes / 16);
    Wr(d->bar_user, XCAP_REG_FIFO_MAX, 0);
    Wr(d->bar_user, XCAP_REG_STALL_MAX, 0);
    Wr(d->bar_user, XCAP_REG_STATUS, XCAP_STATUS_OVERFLOW);
    Wr(d->bar_user, XCAP_REG_CTRL, ctrl | (in->ctrl & (XCAP_CTRL_SRC_HDMI | XCAP_CTRL_TPG_EN)));

    Rd(d->bar_dma, C2H(CH_STATUS_RC));
    Wr(d->bar_dma, C2H_SGDMA(SG_DESC_LO), (ULONG)first);
    Wr(d->bar_dma, C2H_SGDMA(SG_DESC_HI), (ULONG)(first >> 32));
    adj = min(min(15u, d->ndesc - 1), (ULONG)((PAGE_SIZE - (first & (PAGE_SIZE - 1))) / sizeof(XDESC)) - 1);
    Wr(d->bar_dma, C2H_SGDMA(SG_DESC_ADJ), adj);
    Wr(d->bar_dma, C2H(CH_POLL_LO), (ULONG)wb);
    Wr(d->bar_dma, C2H(CH_POLL_HI), (ULONG)(wb >> 32));
    Wr(d->bar_dma, C2H(CH_IE), CTRL_IE_COMPLETED | CTRL_IE_STOPPED | IE_ERRORS);
    if (in->audio) {
        ULONG64 af = WdfCommonBufferGetAlignedLogicalAddress(d->audd_cb).QuadPart;
        ULONG64 aw = WdfCommonBufferGetAlignedLogicalAddress(d->ctl_cb).QuadPart + FIELD_OFFSET(xcap_ctl, aud_hw_count);
        Rd(d->bar_dma, C2HA(CH_STATUS_RC));
        Wr(d->bar_dma, C2HA_SGDMA(SG_DESC_LO), (ULONG)af);
        Wr(d->bar_dma, C2HA_SGDMA(SG_DESC_HI), (ULONG)(af >> 32));
        Wr(d->bar_dma, C2HA_SGDMA(SG_DESC_ADJ), min(15u, (ULONG)((PAGE_SIZE - (af & (PAGE_SIZE - 1))) / sizeof(XDESC)) - 1));
        Wr(d->bar_dma, C2HA(CH_POLL_LO), (ULONG)aw);
        Wr(d->bar_dma, C2HA(CH_POLL_HI), (ULONG)(aw >> 32));
        Wr(d->bar_dma, C2HA(CH_IE), CTRL_IE_COMPLETED | CTRL_IE_STOPPED | IE_ERRORS);
    }
    d->dpc_seen = 0; d->dpc_pos = 0; d->aud_seen = 0;
    d->ctl->state = STATE_STREAMING;
    WdfInterruptAcquireLock(d->interrupt);
    d->streaming = TRUE;
    d->audio_on = (BOOLEAN)(in->audio != 0);
    WdfInterruptReleaseLock(d->interrupt);
    Wr(d->bar_dma, IRQ(IRQ_CH_EN_W1S), C2H_IRQ_BIT | (in->audio ? C2HA_IRQ_BIT : 0));
    KeMemoryBarrier();
    Wr(d->bar_dma, C2H(CH_CTRL), CTRL_RUN | CTRL_POLL_WB | CTRL_IE_COMPLETED | CTRL_IE_STOPPED | IE_ERRORS);
    if (in->audio) Wr(d->bar_dma, C2HA(CH_CTRL), CTRL_RUN | CTRL_POLL_WB | CTRL_IE_COMPLETED | CTRL_IE_STOPPED | IE_ERRORS);
    Rd(d->bar_dma, C2H(CH_STATUS));
    SleepUs(1000);                                    // descriptors are fetched before the first pixel
    Wr(d->bar_user, XCAP_REG_CTRL, Rd(d->bar_user, XCAP_REG_CTRL) | XCAP_CTRL_STREAM_EN | (in->audio ? XCAP_CTRL_AUDIO_EN : 0));
    d->start_total++;
    return STATUS_SUCCESS;
}

BOOLEAN EvtIsr(WDFINTERRUPT interrupt, ULONG message)
{
    DEV *d = DevCtx(WdfInterruptGetDevice(interrupt));
    UNREFERENCED_PARAMETER(message);
    if (!d->streaming) return FALSE;
    // One vector for both engines: mask them (posted write) and go on in the DPC.
    Wr(d->bar_dma, IRQ(IRQ_CH_EN_W1C), C2H_IRQ_BIT | C2HA_IRQ_BIT);
    d->irq_count++;
    d->irq_total++;
    WdfInterruptQueueDpcForIsr(interrupt);
    return TRUE;
}

VOID EvtDpc(WDFINTERRUPT interrupt, WDFOBJECT object)
{
    DEV *d = DevCtx((WDFDEVICE)object);
    ULONG hw, now, done, st, s, enable = C2H_IRQ_BIT;
    BOOLEAN woke = FALSE, fail = FALSE;
    UNREFERENCED_PARAMETER(interrupt);
    if (!d->streaming) return;

    // One vector serves both engines: each consumer is woken for its own engine only.
    hw = d->ctl->hw_desc_count;
    d->ctl->last_irq_qpc = (uint64_t)KeQueryPerformanceCounter(NULL).QuadPart;
    d->ctl->irq_count = d->irq_count;
    if (d->event && (hw & 0xFFFFFFu) != d->dpc_seen) { KeSetEvent(d->event, 2, FALSE); woke = TRUE; }   // wake the consumer first
    if (d->audio_on) {
        ULONG as = Rd(d->bar_dma, C2HA(CH_STATUS_RC));
        ULONG ac = d->ctl->aud_hw_count & 0xFFFFFFu;  // read after the causes were cleared: a later packet interrupts again
        if (as != 0xFFFFFFFFu && (as & ST_ERRORS)) { d->ctl->engine_status = as | 0x80000000u; d->ctl->state = STATE_ERROR; fail = TRUE; }
        if (d->audio_event && (ac != d->aud_seen || (as & (ST_DONE | ST_ERRORS)))) KeSetEvent(d->audio_event, 2, FALSE);
        d->aud_seen = ac;
        enable |= C2HA_IRQ_BIT;
    }

    st = Rd(d->bar_dma, C2H(CH_STATUS_RC));           // clears the interrupt causes
    if (st == 0xFFFFFFFFu) {                          // the card is gone: tell both consumers, leave the interrupts masked
        d->ctl->engine_status = st; d->ctl->state = STATE_ERROR;
        if (d->event) KeSetEvent(d->event, 2, FALSE);
        if (d->audio_event) KeSetEvent(d->audio_event, 2, FALSE);
        return;
    }
    if (st & ST_ERRORS) { d->ctl->engine_status = st; d->ctl->state = STATE_ERROR; fail = TRUE; }
    // A descriptor that completed before the causes were cleared raises no further interrupt: look again.
    now = d->ctl->hw_desc_count;
    if (d->event && (now != hw || (!woke && (st & ST_DONE)))) KeSetEvent(d->event, 2, FALSE);
    hw = now;
    d->ctl->sw_desc_count = hw & 0xFFFFFFu;

    // every frame must end exactly on its last descriptor
    done = ((hw & 0xFFFFFFu) - d->dpc_seen) & 0xFFFFFFu;
    d->dpc_seen = hw & 0xFFFFFFu;
    if (done > d->ndesc) {
        // More than one pass over the ring since the last DPC: the results of the frames in between were
        // overwritten and cannot be checked. Follow the position and go on from there.
        d->dpc_pos = (d->dpc_pos + done) % d->ndesc;
        done = 0;
    }
    while (done) {
        // find the slot the position is in and its end
        ULONG end = 0, step;
        for (s = 0; s < d->slots; s++) { end = d->ctl->slice_end[s][d->slices - 1]; if (d->dpc_pos < end) break; }
        step = min(done, end - d->dpc_pos);
        d->dpc_pos += step; done -= step;
        if (d->dpc_pos == end) {
            XRESULT *r = ResultAt(d, end - 1);
            if ((r->status & 0xFFFF0000u) != WB_MAGIC || !(r->status & WB_EOP) || r->length != DescAt(d, end - 1)->length) {
                d->ctl->align_errors++;
                d->ctl->state = STATE_ERROR;
                fail = TRUE;
            }
            r->status = 0;
            if (end == d->ndesc) d->dpc_pos = 0;
        }
    }
    if (fail) {                                       // an error is for everybody
        if (d->event) KeSetEvent(d->event, 2, FALSE);
        if (d->audio_event) KeSetEvent(d->audio_event, 2, FALSE);
    }
    if (d->streaming) Wr(d->bar_dma, IRQ(IRQ_CH_EN_W1S), enable);
}

// ------------------------------------------------------------------ ioctl ----

static NTSTATUS CheckStart(const xcap_start_in *in, size_t len)
{
    ULONG slices;
    if (len < sizeof(*in) || in->size != sizeof(*in)) return STATUS_INVALID_PARAMETER;
    if (in->slots < 2 || in->slots > XCAP_MAX_SLOTS) return STATUS_INVALID_PARAMETER;
    if (!in->data_bytes || in->data_bytes > 64u * 1024 * 1024 || (in->data_bytes & 15)) return STATUS_INVALID_PARAMETER;
    if (!in->slice_bytes || (in->slice_bytes & 15)) return STATUS_INVALID_PARAMETER;
    slices = (in->data_bytes + in->slice_bytes - 1) / in->slice_bytes;
    if (in->slice_bytes > in->data_bytes) return STATUS_INVALID_PARAMETER;
    if (!slices || slices > XCAP_MAX_BANDS) return STATUS_INVALID_PARAMETER;   // one CRC band per slice; the trailer holds XCAP_MAX_BANDS
    return STATUS_SUCCESS;
}

static NTSTATUS DoStart(DEV *d, WDFFILEOBJECT file, const xcap_start_in *in, size_t in_len, xcap_start_out *out, KPROCESSOR_MODE mode)
{
    NTSTATUS st = CheckStart(in, in_len);
    ULONG s;
    if (!NT_SUCCESS(st)) return st;
    if (!d->hw_ready) return STATUS_DEVICE_NOT_READY;
    ReleaseQuarantine(d);
    if (d->streaming || d->owner || d->stuck || d->mem_valid) return STATUS_DEVICE_BUSY;
    if (in->event) {
        st = ObReferenceObjectByHandle((HANDLE)(ULONG_PTR)in->event, EVENT_MODIFY_STATE, *ExEventObjectType, mode, (PVOID *)&d->event, NULL);
        if (!NT_SUCCESS(st)) { d->event = NULL; return st; }
    }
    if (in->audio && !d->has_audio) { if (d->event) { ObDereferenceObject(d->event); d->event = NULL; } return STATUS_NOT_SUPPORTED; }
    if (in->audio && in->audio_event) {
        st = ObReferenceObjectByHandle((HANDLE)(ULONG_PTR)in->audio_event, EVENT_MODIFY_STATE, *ExEventObjectType, mode, (PVOID *)&d->audio_event, NULL);
        if (!NT_SUCCESS(st)) { d->audio_event = NULL; if (d->event) { ObDereferenceObject(d->event); d->event = NULL; } return st; }
    }
    d->slots = in->slots;
    d->slices = (in->data_bytes + in->slice_bytes - 1) / in->slice_bytes;
    d->frame_bytes = XCAP_HDR_BYTES + ((in->data_bytes + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1)) + XCAP_TRL_BYTES;
    d->owner = file;
    st = AllocAll(d, in);
    if (NT_SUCCESS(st)) st = MapAll(d);
    if (NT_SUCCESS(st)) st = StartEngine(d, in);
    if (!NT_SUCCESS(st)) {
        if (d->event) { ObDereferenceObject(d->event); d->event = NULL; }
        if (d->audio_event) { ObDereferenceObject(d->audio_event); d->audio_event = NULL; }
        StopAll(d);
        return st;
    }
    RtlZeroMemory(out, sizeof(*out));
    out->frame_bytes = d->frame_bytes;
    out->slices = d->slices;
    out->descs_per_ring = d->ndesc;
    out->contiguous_kb = d->contiguous / 1024;
    out->ctl = (uint64_t)(ULONG_PTR)d->ctl_user;
    out->audio_ring = (uint64_t)(ULONG_PTR)d->aud_user;
    for (s = 0; s < d->slots; s++) out->slot[s] = (uint64_t)(ULONG_PTR)d->slot[s].user;
    return STATUS_SUCCESS;
}

static VOID DoClock(DEV *d, xcap_clock *c)
{
    KIRQL irql;
    ULONG i;
    ULONG64 best = ~0ull;
    KeRaiseIrql(DISPATCH_LEVEL, &irql);
    for (i = 0; i < 8; i++) {
        ULONG64 q0 = (ULONG64)KeQueryPerformanceCounter(NULL).QuadPart, q1;
        ULONG lo = Rd(d->bar_user, XCAP_REG_TS_LO);
        ULONG hi;
        q1 = (ULONG64)KeQueryPerformanceCounter(NULL).QuadPart;
        hi = Rd(d->bar_user, XCAP_REG_TS_HI);
        if (q1 - q0 < best) { best = q1 - q0; c->fpga_ticks = ((ULONG64)hi << 32) | lo; c->qpc_before = q0; c->qpc_after = q1; }
    }
    KeLowerIrql(irql);
}

static BOOLEAN RegWritable(ULONG off)
{
    if (off >= XCAP_REG_EDID && off < XCAP_REG_EDID + 256) return TRUE;
    if (off >= XCAP_REG_META0 && off < XCAP_REG_META0 + 4 * XCAP_META_WORDS) return TRUE;
    switch (off) {
    case XCAP_REG_TPG_MODE: case XCAP_REG_TPG_REPEAT: case XCAP_REG_TPG_H: case XCAP_REG_TPG_V:
    case XCAP_REG_FIFO_MAX: case XCAP_REG_STALL_MAX: case XCAP_REG_STATUS: case XCAP_REG_HOST_CTRL: case XCAP_REG_TX_CTRL: case XCAP_REG_TPG_AUDIO: return TRUE;
    }
    return FALSE;
}

// All control codes are handled here, in the caller's process, at PASSIVE_LEVEL.
VOID EvtInCaller(WDFDEVICE device, WDFREQUEST request)
{
    DEV *d = DevCtx(device);
    WDF_REQUEST_PARAMETERS p;
    NTSTATUS st = STATUS_INVALID_DEVICE_REQUEST;
    ULONG_PTR info = 0;
    PVOID ib = NULL, ob = NULL;
    size_t il = 0, ol = 0;
    ULONG code;
    WDFFILEOBJECT file = WdfRequestGetFileObject(request);
    BOOLEAN foreign;

    WDF_REQUEST_PARAMETERS_INIT(&p);
    WdfRequestGetParameters(request, &p);
    if (p.Type != WdfRequestTypeDeviceControl) { WdfRequestComplete(request, STATUS_INVALID_DEVICE_REQUEST); return; }
    code = p.Parameters.DeviceIoControl.IoControlCode;
    if (p.Parameters.DeviceIoControl.InputBufferLength) WdfRequestRetrieveInputBuffer(request, 1, &ib, &il);
    if (p.Parameters.DeviceIoControl.OutputBufferLength) WdfRequestRetrieveOutputBuffer(request, 1, &ob, &ol);

    WdfWaitLockAcquire(d->lock, NULL);
    // A card that stopped answering returns all ones after a long timeout. Touch the user registers once,
    // then not again before the next STOP or START (the DMA block is stopped on its own, see StopEngine).
    if (d->hw_ready && Rd(d->bar_user, XCAP_REG_ID) != XCAP_ID_MAGIC) {
        d->hw_ready = FALSE;
        if (d->ctl) d->ctl->state = STATE_ERROR;
    } else if (!d->hw_ready && d->d0 && code == XCAP_IOCTL_START && Rd(d->bar_user, XCAP_REG_ID) == XCAP_ID_MAGIC) d->hw_ready = TRUE;
    // The handle of the capturing process duplicated into another one: that one may look, not touch.
    foreign = (BOOLEAN)(d->owner && d->owner == file && d->owner_process != PsGetCurrentProcess());
    if (!d->hw_ready && code != XCAP_IOCTL_STOP) st = STATUS_DEVICE_NOT_READY;
    else switch (code) {
    case XCAP_IOCTL_INFO:
        if (ol < sizeof(xcap_info)) { st = STATUS_BUFFER_TOO_SMALL; break; }
        {
            xcap_info *o = (xcap_info *)ob;
            RtlZeroMemory(o, sizeof(*o));
            o->drv_version = XCAP_DRV_VERSION;
            o->hw_version = Rd(d->bar_user, XCAP_REG_VERSION);
            o->status_reg = Rd(d->bar_user, XCAP_REG_STATUS);
            o->xdma_c2h_id = d->c2h_id;
            o->xdma_cfg_id = Rd(d->bar_dma, CFG(0));
            o->streaming = d->streaming; o->engine_stuck = d->stuck;
            o->irq_total = d->irq_total; o->start_total = d->start_total;
            if (d->have_bus) {
                UCHAR cap = 0, id = 0, guard = 48;
                d->bus.GetBusData(d->bus.Context, PCI_WHICHSPACE_CONFIG, &cap, FIELD_OFFSET(PCI_COMMON_CONFIG, u.type0.CapabilitiesPtr), 1);
                while (cap >= 0x40 && guard--) {
                    UCHAR next = 0;
                    d->bus.GetBusData(d->bus.Context, PCI_WHICHSPACE_CONFIG, &id, cap, 1);
                    d->bus.GetBusData(d->bus.Context, PCI_WHICHSPACE_CONFIG, &next, cap + 1u, 1);
                    if (id == PCI_CAPABILITY_ID_PCI_EXPRESS) {
                        USHORT devctl = 0, lnk = 0;
                        d->bus.GetBusData(d->bus.Context, PCI_WHICHSPACE_CONFIG, &devctl, cap + 0x08u, 2);
                        d->bus.GetBusData(d->bus.Context, PCI_WHICHSPACE_CONFIG, &lnk, cap + 0x12u, 2);
                        o->link_speed = lnk & 0xF; o->link_width = (lnk >> 4) & 0x3F;
                        o->max_payload = 128u << ((devctl >> 5) & 7); o->max_read_request = 128u << ((devctl >> 12) & 7);
                        break;
                    }
                    cap = next;
                }
            }
            info = sizeof(*o); st = STATUS_SUCCESS;
        }
        break;
    case XCAP_IOCTL_REG_RD:
        if (il < sizeof(xcap_reg) || ol < sizeof(xcap_reg)) { st = STATUS_BUFFER_TOO_SMALL; break; }
        {
            xcap_reg r = *(xcap_reg *)ib;
            if ((r.offset & 3) || r.offset >= 0x1000) { st = STATUS_INVALID_PARAMETER; break; }
            r.value = Rd(d->bar_user, r.offset);
            *(xcap_reg *)ob = r; info = sizeof(r); st = STATUS_SUCCESS;
        }
        break;
    case XCAP_IOCTL_REG_WR:
        if (il < sizeof(xcap_reg)) { st = STATUS_BUFFER_TOO_SMALL; break; }
        {
            xcap_reg r = *(xcap_reg *)ib;
            if ((r.offset & 3) || !RegWritable(r.offset)) { st = STATUS_INVALID_PARAMETER; break; }
            if (d->owner && d->owner != file) { st = STATUS_DEVICE_BUSY; break; }
            if (foreign) { st = STATUS_ACCESS_DENIED; break; }
            Wr(d->bar_user, r.offset, r.value); st = STATUS_SUCCESS;
        }
        break;
    case XCAP_IOCTL_CLOCK:
        if (ol < sizeof(xcap_clock)) { st = STATUS_BUFFER_TOO_SMALL; break; }
        DoClock(d, (xcap_clock *)ob); info = sizeof(xcap_clock); st = STATUS_SUCCESS;
        break;
    case XCAP_IOCTL_START:
        if (il < sizeof(xcap_start_in) || ol < sizeof(xcap_start_out)) { st = STATUS_BUFFER_TOO_SMALL; break; }
        {
            xcap_start_in in = *(xcap_start_in *)ib;      // input and output share the system buffer
            st = DoStart(d, file, &in, il, (xcap_start_out *)ob, WdfRequestGetRequestorMode(request));
            if (NT_SUCCESS(st)) info = sizeof(xcap_start_out);
        }
        break;
    case XCAP_IOCTL_STOP:
        if (!d->owner) { st = STATUS_SUCCESS; break; }
        if (d->owner != file) { st = STATUS_DEVICE_BUSY; break; }
        if (foreign) { st = STATUS_ACCESS_DENIED; break; }
        if (!d->bar_dma) d->stuck = FALSE;            // hardware released: the device is stopped or gone
        StopAll(d); st = STATUS_SUCCESS;              // in the owner: the views can always be removed
        break;
    }
    WdfWaitLockRelease(d->lock);
    WdfRequestCompleteWithInformation(request, st, info);
}

// The last handle to the file is closed, in whatever process held it.
VOID EvtFileCleanup(WDFFILEOBJECT file)
{
    DEV *d = DevCtx(WdfFileObjectGetDevice(file));
    ULONG tries;
    for (tries = 0;; tries++) {
        BOOLEAN done = TRUE;
        WdfWaitLockAcquire(d->lock, NULL);
        if (d->owner == file) {
            if (!d->bar_dma) d->stuck = FALSE;        // hardware released: the device is stopped or gone
            done = StopAll(d);
            // Not done: the views are in another process that is exiting right now. Its exit callback
            // removes them in a moment; without that callback, or after 5 s, they are left to the memory manager.
            if (!done && (!g_notify || tries >= 250)) { AbandonViews(d); done = TRUE; }
        }
        WdfWaitLockRelease(d->lock);
        if (done) break;
        SleepUs(20000);
    }
}

// A process exits (called in that process, before its address space is deleted). When it is the one the
// ring is mapped into, the capture ends here: the file object may live on through a duplicated or
// inherited handle, and then no cleanup arrives while the views can still be removed.
VOID EvtProcessNotify(PEPROCESS process, HANDLE pid, PPS_CREATE_NOTIFY_INFO info)
{
    ULONG i;
    UNREFERENCED_PARAMETER(pid);
    if (info) return;                                 // a new process
    WdfWaitLockAcquire(g_lock, NULL);
    for (i = 0; i < MAX_DEVICES; i++) {
        DEV *d = g_dev[i];
        if (!d || d->owner_process != process) continue;   // looked at without the device lock: an exiting process does not become an owner
        WdfWaitLockAcquire(d->lock, NULL);
        if (d->owner_process == process) {
            if (!d->bar_dma) d->stuck = FALSE;
            if (!StopAll(d)) AbandonViews(d);
        }
        WdfWaitLockRelease(d->lock);
    }
    WdfWaitLockRelease(g_lock);
}

// -------------------------------------------------------------------- pnp ----

NTSTATUS EvtPrepare(WDFDEVICE device, WDFCMRESLIST raw, WDFCMRESLIST translated)
{
    DEV *d = DevCtx(device);
    ULONG i, n = WdfCmResourceListGetCount(translated);
    ULONG id;
    UNREFERENCED_PARAMETER(raw);
    for (i = 0; i < n; i++) {
        PCM_PARTIAL_RESOURCE_DESCRIPTOR r = WdfCmResourceListGetDescriptor(translated, i);
        PUCHAR va;
        if (r->Type != CmResourceTypeMemory) continue;
        if (d->bar_user && d->bar_dma) continue;
        va = (PUCHAR)MmMapIoSpaceEx(r->u.Memory.Start, r->u.Memory.Length, PAGE_READWRITE | PAGE_NOCACHE);
        if (!va) return STATUS_INSUFFICIENT_RESOURCES;
        if (!d->bar_user) { d->bar_user = va; d->bar_user_len = r->u.Memory.Length; }
        else              { d->bar_dma = va;  d->bar_dma_len = r->u.Memory.Length; }
    }
    if (!d->bar_user || !d->bar_dma || d->bar_user_len < 0x1000 || d->bar_dma_len < 0x8000) return STATUS_DEVICE_CONFIGURATION_ERROR;
    // which BAR is which: the DMA block identifies itself with 0x1FCx
    id = Rd(d->bar_dma, C2H(CH_ID));
    if ((id >> 20) != 0x1FC) {
        PUCHAR t = d->bar_user; SIZE_T l = d->bar_user_len;
        d->bar_user = d->bar_dma; d->bar_user_len = d->bar_dma_len;
        d->bar_dma = t; d->bar_dma_len = l;
        id = Rd(d->bar_dma, C2H(CH_ID));
    }
    d->c2h_id = id;
    if ((id >> 20) != 0x1FC || !(id & 0x8000)) return STATUS_DEVICE_CONFIGURATION_ERROR;   // not a stream engine
    if (Rd(d->bar_user, XCAP_REG_ID) != XCAP_ID_MAGIC) return STATUS_DEVICE_CONFIGURATION_ERROR;
    d->has_audio = (BOOLEAN)((Rd(d->bar_dma, C2HA(CH_ID)) >> 20) == 0x1FC && Rd(d->bar_user, XCAP_REG_VERSION) >= 0x00030000u);
    return STATUS_SUCCESS;
}

NTSTATUS EvtRelease(WDFDEVICE device, WDFCMRESLIST translated)
{
    DEV *d = DevCtx(device);
    UNREFERENCED_PARAMETER(translated);
    WdfWaitLockAcquire(d->lock, NULL);
    if (d->mem_valid && !d->owner) {                  // quarantined memory: the device is powered off now
        d->stuck = FALSE; d->orphaned = FALSE;
        FreeMemory(d);
    }
    WdfWaitLockRelease(d->lock);
    if (d->bar_user) { MmUnmapIoSpace(d->bar_user, d->bar_user_len); d->bar_user = NULL; }
    if (d->bar_dma)  { MmUnmapIoSpace(d->bar_dma, d->bar_dma_len); d->bar_dma = NULL; }
    return STATUS_SUCCESS;
}

NTSTATUS EvtD0Entry(WDFDEVICE device, WDF_POWER_DEVICE_STATE previous)
{
    DEV *d = DevCtx(device);
    UNREFERENCED_PARAMETER(previous);
    WdfWaitLockAcquire(d->lock, NULL);
    Wr(d->bar_user, XCAP_REG_CTRL, 0);
    Wr(d->bar_dma, IRQ(IRQ_CH_EN_W1C), 0xFFFFFFFFu);
    Wr(d->bar_dma, IRQ(IRQ_USR_EN_W1C), 0xFFFFFFFFu);
    Wr(d->bar_dma, IRQ(IRQ_CH_VEC0), 0);
    Wr(d->bar_dma, IRQ(IRQ_USR_VEC0), 0);
    Wr(d->bar_dma, C2H(CH_CTRL_W1C), CTRL_RUN);
    if (d->has_audio) Wr(d->bar_dma, C2HA(CH_CTRL_W1C), CTRL_RUN);
    d->d0 = TRUE;
    d->hw_ready = TRUE;
    ReleaseQuarantine(d);                             // an engine that would not stop before: look again, give the ring back when it is idle now
    WdfWaitLockRelease(d->lock);
    return STATUS_SUCCESS;
}

NTSTATUS EvtD0Exit(WDFDEVICE device, WDF_POWER_DEVICE_STATE target)
{
    DEV *d = DevCtx(device);
    UNREFERENCED_PARAMETER(target);
    WdfWaitLockAcquire(d->lock, NULL);
    StopEngine(d);                                    // views stay mapped until the handle is closed
    if (d->ctl) d->ctl->state = STATE_ERROR;
    d->hw_ready = FALSE;
    d->d0 = FALSE;
    WdfWaitLockRelease(d->lock);
    return STATUS_SUCCESS;
}

VOID EvtDeviceCleanup(WDFOBJECT object)
{
    DEV *d = DevCtx((WDFDEVICE)object);
    ULONG i;
    WdfWaitLockAcquire(g_lock, NULL);
    for (i = 0; i < MAX_DEVICES; i++) if (g_dev[i] == d) g_dev[i] = NULL;
    WdfWaitLockRelease(g_lock);
    if (d->have_bus) { d->bus.InterfaceDereference(d->bus.Context); d->have_bus = FALSE; }
}

NTSTATUS EvtDeviceAdd(WDFDRIVER driver, PWDFDEVICE_INIT init)
{
    WDF_PNPPOWER_EVENT_CALLBACKS pnp;
    WDF_OBJECT_ATTRIBUTES attr;
    WDF_FILEOBJECT_CONFIG fc;
    WDF_INTERRUPT_CONFIG ic;
    WDF_DMA_ENABLER_CONFIG dc;
    WDFDEVICE device;
    DEV *d;
    NTSTATUS st;
    ULONG i;
    UNREFERENCED_PARAMETER(driver);

    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnp);
    pnp.EvtDevicePrepareHardware = EvtPrepare;
    pnp.EvtDeviceReleaseHardware = EvtRelease;
    pnp.EvtDeviceD0Entry = EvtD0Entry;
    pnp.EvtDeviceD0Exit = EvtD0Exit;
    WdfDeviceInitSetPnpPowerEventCallbacks(init, &pnp);
    WDF_FILEOBJECT_CONFIG_INIT(&fc, WDF_NO_EVENT_CALLBACK, WDF_NO_EVENT_CALLBACK, EvtFileCleanup);
    WdfDeviceInitSetFileObjectConfig(init, &fc, WDF_NO_OBJECT_ATTRIBUTES);
    WdfDeviceInitSetIoInCallerContextCallback(init, EvtInCaller);
    WdfDeviceInitSetIoType(init, WdfDeviceIoBuffered);

    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attr, DEV);
    attr.EvtCleanupCallback = EvtDeviceCleanup;
    attr.ExecutionLevel = WdfExecutionLevelPassive;
    attr.SynchronizationScope = WdfSynchronizationScopeNone;
    st = WdfDeviceCreate(&init, &attr, &device);
    if (!NT_SUCCESS(st)) return st;
    d = DevCtx(device);
    d->device = device;

    WDF_OBJECT_ATTRIBUTES_INIT(&attr);
    attr.ParentObject = device;
    st = WdfWaitLockCreate(&attr, &d->lock);
    if (!NT_SUCCESS(st)) return st;
    WdfWaitLockAcquire(g_lock, NULL);                 // where the process exit callback finds the device
    for (i = 0; i < MAX_DEVICES; i++) if (!g_dev[i]) { g_dev[i] = d; break; }
    WdfWaitLockRelease(g_lock);
    if (i == MAX_DEVICES) return STATUS_INSUFFICIENT_RESOURCES;

    WdfDeviceSetAlignmentRequirement(device, FILE_64_BYTE_ALIGNMENT);
    WDF_DMA_ENABLER_CONFIG_INIT(&dc, WdfDmaProfileScatterGather64, SG_CHUNK + PAGE_SIZE);
    st = WdfDmaEnablerCreate(device, &dc, WDF_NO_OBJECT_ATTRIBUTES, &d->enabler);
    if (!NT_SUCCESS(st)) return st;
    d->adapter = WdfDmaEnablerWdmGetDmaAdapter(d->enabler, WdfDmaDirectionReadFromDevice);

    WDF_INTERRUPT_CONFIG_INIT(&ic, EvtIsr, EvtDpc);
    st = WdfInterruptCreate(device, &ic, WDF_NO_OBJECT_ATTRIBUTES, &d->interrupt);
    if (!NT_SUCCESS(st)) return st;

    st = WdfFdoQueryForInterface(device, &GUID_BUS_INTERFACE_STANDARD, (PINTERFACE)&d->bus, sizeof(d->bus), 1, NULL);
    d->have_bus = (BOOLEAN)NT_SUCCESS(st);

    return WdfDeviceCreateDeviceInterface(device, &GUID_DEVINTERFACE_XCAP, NULL);
}

VOID EvtDriverUnload(WDFDRIVER driver)
{
    UNREFERENCED_PARAMETER(driver);
    if (g_notify) { PsSetCreateProcessNotifyRoutineEx(EvtProcessNotify, TRUE); g_notify = FALSE; }   // waits for a callback that is running
}

NTSTATUS DriverEntry(PDRIVER_OBJECT object, PUNICODE_STRING path)
{
    WDF_DRIVER_CONFIG cfg;
    NTSTATUS st;
    ExInitializeDriverRuntime(DrvRtPoolNxOptIn);
    WDF_DRIVER_CONFIG_INIT(&cfg, EvtDeviceAdd);
    cfg.EvtDriverUnload = EvtDriverUnload;
    st = WdfDriverCreate(object, path, WDF_NO_OBJECT_ATTRIBUTES, &cfg, WDF_NO_HANDLE);
    if (!NT_SUCCESS(st)) return st;
    st = WdfWaitLockCreate(WDF_NO_OBJECT_ATTRIBUTES, &g_lock);     // child of the driver object
    if (!NT_SUCCESS(st)) return st;
    // Last, so that nothing is left to undo. Without it (the image must be linked with /INTEGRITYCHECK)
    // the driver still works; EvtFileCleanup then never touches the address space of an exiting process.
    g_notify = (BOOLEAN)NT_SUCCESS(PsSetCreateProcessNotifyRoutineEx(EvtProcessNotify, FALSE));
    return STATUS_SUCCESS;
}
