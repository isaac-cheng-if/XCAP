// xcap_test info
// xcap_test edid pcm|atmos|tv [apply]
// xcap_test run  [seconds] [v210|bgrx] [slice lines] [spin us] [hz] [audio words/s]
// xcap_test clock
// xcap_test loop [mode] [audio] [seconds] [hdr2]   HDMI OUT -> IN cable: mode 0 4K60 HDR10, 1 4K60 SDR, 2 1080p60 RGB, 3 4K30 HDR10, 4 4K60 RGB; audio 0 off 1 stereo 2 eight ch
// xcap_test tx off
// xcap_test loopout on|off|force   HDMI OUT repeats HDMI IN (default on; force: also without a sink, for link captures)
// xcap_test hpd [ms]   pulse HDMI IN hot plug low (source re-reads EDID)
// xcap_test record <frames> <audio seconds> <clip file> <audio file>   for XCAP_SIM clip= / pcm= replay
// xcap_test grab [seconds] [frame file] [audio file]   real HDMI source: check the stream, save one frame (header + pixels) and the audio words
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <string>
#include <thread>
#include <atomic>
#include <vector>
#include "xcap.h"
#include "xcap_edid.h"
using namespace xcap;

static int64_t qpcFreq() { static int64_t f = [] { LARGE_INTEGER x; QueryPerformanceFrequency(&x); return x.QuadPart; }(); return f; }
static int64_t qpc() { LARGE_INTEGER x; QueryPerformanceCounter(&x); return x.QuadPart; }

static void stat(const char* name, std::vector<double>& v) {
    if (v.empty()) { printf("  %-34s -\n", name); return; }
    std::sort(v.begin(), v.end());
    auto at = [&](double p) { return v[std::min(v.size() - 1, size_t(p * (v.size() - 1)))]; };
    printf("  %-34s min %8.1f  p50 %8.1f  p99 %8.1f  max %8.1f us\n", name, v.front(), at(.5), at(.99), v.back());
}

// The FPGA test pattern (see fpga/rtl/xcap_tpg.sv).
static bool checkPattern(const uint8_t* pix, uint32_t w, uint32_t h, uint32_t stride, uint32_t fmt, uint32_t n, uint32_t* badY, uint32_t* badX) {
    const auto Y = [&](uint32_t x, uint32_t y) { return (x + 3 * y + 7 * n) & 0x3FF; };
    const auto C = [&](uint32_t x, uint32_t y) { return (x ^ y ^ (5 * n)) & 0x3FF; };
    std::vector<uint32_t> line(stride / 4);
    for (uint32_t y = 0; y < h; ++y) {
        uint32_t* o = line.data();
        if (fmt == XCAP_PIXFMT_V210) {
            for (uint32_t x = 0; x < w; x += 6) {
                *o++ = C(x, y) | Y(x, y) << 10 | C(x + 1, y) << 20;
                *o++ = Y(x + 1, y) | C(x + 2, y) << 10 | Y(x + 2, y) << 20;
                *o++ = C(x + 3, y) | Y(x + 3, y) << 10 | C(x + 4, y) << 20;
                *o++ = Y(x + 4, y) | C(x + 5, y) << 10 | Y(x + 5, y) << 20;
            }
        } else {
            for (uint32_t x = 0; x < w; ++x) { const uint32_t g = Y(x, y), b = C(x, y), r = g ^ b; *o++ = (b >> 2) | (g >> 2) << 8 | (r >> 2) << 16 | 0xFF000000u; }
        }
        if (memcmp(line.data(), pix + size_t(y) * stride, stride)) {
            *badY = y;
            for (uint32_t i = 0; i < line.size(); ++i) if (line[i] != reinterpret_cast<const uint32_t*>(pix + size_t(y) * stride)[i]) { *badX = i; break; }
            return false;
        }
    }
    return true;
}

static int cmdInfo(Device& d) {
    xcap_info i{};
    if (!d.info(i)) { printf("INFO failed %lu\n", d.lastError()); return 1; }
    printf("driver %08x  hw %08x  c2h id %08x  cfg id %08x\n", i.drv_version, i.hw_version, i.xdma_c2h_id, i.xdma_cfg_id);
    printf("link Gen%u x%u  MPS %u  MRRS %u  status %08x  streaming %u  stuck %u  irq %llu  starts %llu\n", i.link_speed, i.link_width,
        i.max_payload, i.max_read_request, i.status_reg, i.streaming, i.engine_stuck, i.irq_total, i.start_total);
    return 0;
}

struct AudioCheck {
    uint64_t packets = 0, words = 0, gaps = 0, seqErr = 0, bad = 0, lost = 0; double latMax = 0;
    uint64_t rateWords = 0, ticks = 0, t0 = 0, t1 = 0; uint32_t prevWords = 0; bool first = true;   // rate by FPGA time, start-up backlog excluded
    double rate() const { return t1 > t0 ? double(rateWords) / (double(t1 - t0) * 4e-9) : 0; }
    std::atomic<bool> run{true}; std::thread t;
    void start(Device& d, Clock ck, double usPerTick) {
        t = std::thread([this, &d, ck, usPerTick] {
            SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
            uint64_t n = 0; uint32_t seq = 0, exp = 0; bool have = false;
            while (run) {
                WaitForSingleObject(d.audioEvent(), 20);
                const uint64_t done = d.audioPackets();
                if (done > n + XCAP_AUD_RING - 8) { lost += done - n; n = done; have = false; }
                for (; n < done; ++n) {
                    const xcap_audio_packet* p = d.audioPacket(n);
                    if (p->magic != XCAP_AUD_MAGIC || p->words > XCAP_AUD_WORDS) { ++bad; continue; }
                    if (have && p->seq != seq) ++seqErr;
                    seq = p->seq + 1;
                    ticks = first ? ck.ticks + int32_t(p->ts - uint32_t(ck.ticks)) : ticks + uint32_t(p->ts - uint32_t(ticks)); first = false;
                    const double us = double(qpc() - ck.qpc) * 1e6 / qpcFreq() - double(int64_t(ticks - ck.ticks)) * usPerTick;
                    if (!t0 && us < 5000) { t0 = ticks; rateWords = 0; }
                    else if (t0) { t1 = ticks; rateWords += prevWords; latMax = std::max(latMax, us); }
                    prevWords = p->words;
                    for (uint32_t i = 0; i < p->words; ++i) {
                        const uint32_t w = p->word[i];
                        if (!(w & 0x80000000u)) ++bad;
                        if (have && XCAP_AUD_SAMPLE(w) != exp) ++gaps;
                        exp = (XCAP_AUD_SAMPLE(w) + 1) & 0xFFFFFF; have = true;
                    }
                    words += p->words; ++packets;
                }
            }
        });
    }
    void stop() { run = false; if (t.joinable()) t.join(); }
};

static int cmdRun(Device& d, double seconds, uint32_t fmt, uint32_t sliceLines, uint32_t spin, double hz, uint32_t audioRate) {
    Config c; c.pixfmt = fmt; c.sliceLines = sliceLines; c.audio = audioRate != 0;
    if (audioRate) d.write(XCAP_REG_TPG_AUDIO, audioRate);
    // two pixels per clock; shorten the blanking only when a higher rate is asked for
    uint32_t vclkHz = 0; d.read(XCAP_REG_VCLK_HZ, vclkHz);
    const double vclk = vclkHz == 300000000u ? 300e6 : 297e6;
    uint32_t vt = 2250, ht = uint32_t(vclk / (60.0 * vt));
    if (hz > 60.01) { vt = 2180; ht = uint32_t(vclk / (hz * vt)); if (ht < 1928) { ht = 1928; } }
    d.write(XCAP_REG_TPG_MODE, XCAP_TPG_VERIFY);
    d.write(XCAP_REG_TPG_REPEAT, 2);
    d.write(XCAP_REG_TPG_H, 1920u | ht << 16);
    d.write(XCAP_REG_TPG_V, 2160u | vt << 16);
    const double rate = vclk / (double(ht) * vt);
    SetPriorityClass(GetCurrentProcess(), HIGH_PRIORITY_CLASS);
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
    const int64_t t0 = qpc();
    if (!d.start(c)) { printf("START failed %lu\n", d.lastError()); return 1; }
    printf("start took %.1f ms  frame %u bytes  slices %u  descriptors/ring %u  contiguous %u KB  rate %.3f Hz = %.3f GB/s\n",
        (qpc() - t0) * 1e3 / qpcFreq(), d.layout().frame_bytes, d.slicesPerFrame(), d.layout().descs_per_ring, d.layout().contiguous_kb,
        rate, rate * d.layout().frame_bytes / 1e9);
    uint32_t drop0 = 0, bad0 = 0; d.read(XCAP_REG_FRAMES_DROP, drop0); d.read(XCAP_REG_FRAMES_BAD, bad0);
    const uint32_t S = d.slicesPerFrame();
    Clock ck0; d.clock(ck0); Sleep(120); Clock ck; d.clock(ck);
    // the FPGA clock follows the (spread-spectrum) PCIe reference, so its rate is measured, not assumed
    double usPerTick = double(ck.qpc - ck0.qpc) * 1e6 / qpcFreq() / double(ck.ticks - ck0.ticks);
    auto toUs = [&](uint64_t ticks, int64_t q) { return double(q - ck.qpc) * 1e6 / qpcFreq() - double(int64_t(ticks - ck.ticks)) * usPerTick; };
    AudioCheck audio; if (audioRate) audio.start(d, ck, usPerTick);
    std::vector<double> lastLat, firstLat, sliceGap, inter, outLat; lastLat.reserve(100000);
    uint64_t frames = 0, crcErr = 0, seqErr = 0, hdrErr = 0, bad = 0, rep = 0, disc = 0, patChecked = 0, patErr = 0, late = 0, overrun = 0, bandMismatch = 0, skipped = 0;
    uint32_t expect = 0; bool have = false;
    int64_t end = qpc() + int64_t(seconds * qpcFreq()), lastDone = 0;
    uint32_t lastN = ~0u;
    std::vector<uint8_t> copy(d.dataBytes());
    std::atomic<int> busy{0}; std::thread checker;
    for (uint64_t f = d.slicesDone() / S + 1; qpc() < end; ++f) {
        // a consumer that fell behind continues with the newest frame
        if (const uint64_t done = d.slicesDone() / S; done > f + 1) { skipped += done - f; f = done; have = false; }
        // follow the slices of this frame one by one
        auto w = d.waitSlices(f * S + 1, 1000, spin);
        if (w != Device::Wait::Ok) { printf("frame %llu: %s  state %u  status %08x  align errors %u  done %llu\n", f, w == Device::Wait::Timeout ? "timeout" : "stopped",
            d.ctl()->state, d.ctl()->engine_status, d.ctl()->align_errors, d.slicesDone()); break; }
        int64_t q1 = qpc();
        const xcap_frame_header* h = d.header(f);
        if (h->magic != XCAP_HDR_MAGIC) ++hdrErr;
        else firstLat.push_back(toUs(h->ts_first_pixel, q1));
        uint32_t crc[4] = { ~0u, ~0u, ~0u, ~0u };
        const uint32_t sliceBytes = d.stride() * c.sliceLines, total = d.dataBytes();
        for (uint32_t s = 0; s < S; ++s) {
            w = d.waitSlices(f * S + s + 1, 1000, spin);
            if (w != Device::Wait::Ok) break;
            if (s + 1 == S) { q1 = qpc(); }
            const uint32_t off = s * sliceBytes;
            crcLanes(d.pixels(f) + off, std::min(sliceBytes, total - off), crc);
        }
        if (w != Device::Wait::Ok) { printf("frame %llu mid-frame stop, state %u status %08x align %u\n", f, d.ctl()->state, d.ctl()->engine_status, d.ctl()->align_errors); break; }
        const xcap_frame_trailer* t = d.trailer(f);
        const xcap_frame_trailer tr = *t; const uint32_t n = h->reserved0, seq = h->seq, hf = h->flags;
        if (!d.frameIntact(f)) { ++overrun; continue; }
        ++frames;
        if (tr.magic != XCAP_TRL_MAGIC || tr.seq != seq) ++hdrErr;
        if (have && seq != expect) ++seqErr;
        have = true; expect = seq + 1;
        if (tr.flags & XCAP_FRAME_BAD) ++bad;
        if (tr.flags & XCAP_FRAME_REPEAT) ++rep;
        if (hf & XCAP_FRAME_DISCONT) ++disc;
        if (memcmp(crc, tr.crc, 16)) ++crcErr;
        if (tr.bands && tr.bands <= XCAP_MAX_BANDS && memcmp(tr.band_crc[tr.bands - 1], tr.crc, 16)) ++bandMismatch;
        lastLat.push_back(toUs(tr.ts_last_pixel, q1));
        outLat.push_back(double(int64_t(tr.ts_last_out - tr.ts_last_pixel)) * 0.004);
        if (lastDone) inter.push_back((q1 - lastDone) * 1e6 / qpcFreq());
        lastDone = q1;
        lastN = n;
        if (!busy.load() && frames % 15 == 1) {
            memcpy(copy.data(), d.pixels(f), copy.size());
            if (d.frameIntact(f)) {
                if (checker.joinable()) checker.join();
                busy = 1; ++patChecked;
                checker = std::thread([&, n] { uint32_t y = 0, x = 0; if (!checkPattern(copy.data(), c.width, c.height, d.stride(), fmt, n, &y, &x)) { ++patErr; printf("pattern error picture %u line %u word %u\n", n, y, x); } busy = 0; });
            }
        }
        if (d.slicesDone() >= (f + 2) * S) ++late;
        if (frames % 15 == 0) { ck0 = ck; d.clock(ck); usPerTick = double(ck.qpc - ck0.qpc) * 1e6 / qpcFreq() / double(ck.ticks - ck0.ticks); }
    }
    if (checker.joinable()) checker.join();
    audio.stop();
    uint32_t audOvf = 0; d.read(XCAP_REG_AUD_OVERFLOW, audOvf);
    uint32_t v[8]{}; const uint32_t regs[8] = { XCAP_REG_FRAMES_IN, XCAP_REG_FRAMES_OUT, XCAP_REG_FRAMES_DROP, XCAP_REG_FRAMES_BAD, XCAP_REG_FIFO_MAX, XCAP_REG_STALL_MAX, XCAP_REG_STATUS, XCAP_REG_CTRL };
    for (int i = 0; i < 8; ++i) d.read(regs[i], v[i]);
    v[2] -= drop0; v[3] -= bad0;
    const uint32_t irq = d.ctl()->irq_count, align = d.ctl()->align_errors, est = d.ctl()->engine_status, state = d.ctl()->state;
    const int64_t s0 = qpc(); d.stop(); const double stopMs = (qpc() - s0) * 1e3 / qpcFreq();
    xcap_info inf{}; d.info(inf);
    printf("frames %llu  (%.3f fps)  data %.2f GB\n", frames, inter.empty() ? 0.0 : 1e6 * inter.size() / [&] { double s = 0; for (double x : inter) s += x; return s; }(), double(frames) * d.dataBytes() / 1e9);
    printf("ERRORS  crc %llu  pattern %llu (checked %llu)  seq %llu  header/trailer %llu  band %llu  overrun %llu  align %u  engine %08x state %u\n", crcErr, patErr, patChecked, seqErr, hdrErr, bandMismatch, overrun, align, est, state);
    printf("flags   bad %llu  repeat %llu  discont %llu   consumer late %llu skipped %llu\n", bad, rep, disc, late, skipped);
    printf("fpga    in %u out %u drop %u bad %u  fifo max %u/8192 words (%.1f us)  longest stall %.2f us  status %08x\n", v[0], v[1], v[2], v[3], v[4], v[4] * 16.0 / (rate * d.dataBytes()) * 1e6, v[5] * 0.004, v[6]);
    printf("irq %u  stop %.1f ms  stuck %u\n", irq, stopMs, inf.engine_stuck);
    if (audioRate) printf("AUDIO   packets %llu  words/s %.0f (want %u)  gaps %llu  seq %llu  bad %llu  lost %llu  overflow %u  packet start -> app max %.0f us\n", audio.packets, audio.rate(), audioRate, audio.gaps, audio.seqErr, audio.bad, audio.lost, audOvf, audio.latMax);
    printf("fpga clock %.1f ppm vs host\n", (0.004 / usPerTick - 1) * 1e6);
    stat("first pixel -> first slice seen", firstLat);
    stat("LAST pixel -> whole frame seen", lastLat);
    stat("last pixel -> last beat into DMA", outLat);
    stat("frame interval", inter);
    const bool ok = frames && !crcErr && !patErr && !seqErr && !hdrErr && !overrun && !align && !bad && !disc && v[2] <= 1 && !v[3] && !inf.engine_stuck &&
        (!audioRate || (audio.packets && !audio.gaps && !audio.seqErr && !audio.bad && !audio.lost && std::abs(audio.rate() - audioRate) < audioRate * 0.002));
    printf("%s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

// Transmitter -> cable -> receiver -> capture, all on this card.
static int cmdLoop(Device& d, int mode, int audio, double seconds, bool hdr2) {
    uint32_t hw = 0;
    if (!d.read(XCAP_REG_VERSION, hw) || hw < 0x00030200u) { printf("FPGA image %08x has no transmitter\n", hw); return 1; }
    const uint32_t seq = uint32_t(GetTickCount()) & 0xFFFFu;
    d.write(XCAP_REG_TX_CTRL, 1u | uint32_t(mode & 7) << 1 | uint32_t(audio & 15) << 4 | (hdr2 ? 0x100u : 0u) | 0x200u | seq << 16);
    uint32_t m[16]{};
    const auto meta = [&] { for (int i = 0; i < 16; ++i) d.read(XCAP_REG_HDMI0 + 4 * i, m[i]); };
    const int64_t t0 = qpc();
    bool locked = false;
    for (int i = 0; i < 150 && !locked; ++i) { Sleep(100); meta(); locked = (m[XCAP_META_STATE] & 1) && (m[XCAP_META_GEOM] & 0xFFFF); }
    const uint32_t tx = m[XCAP_META_CHANGES] >> 16;
    printf("TX: sink %s, stream %s, clock chip %s, mode %u, starts %u\n", (tx & 1) ? "connected" : "NOT CONNECTED", (tx & 2) ? "up" : "DOWN", (tx & 8) ? "FAILED" : (tx & 4) ? "ok" : "?", (tx >> 5) & 7, (tx >> 8) & 255);
    if (!locked) { printf("RX: no lock after %.1f s, refclk %u kHz, 5V %s, errors %08x\nFAIL\n", double(qpc() - t0) / qpcFreq(), m[XCAP_META_REFCLK], (m[XCAP_META_STATE] & 128) ? "on" : "off", m[XCAP_META_ERRORS]); return 1; }
    const uint32_t w = m[XCAP_META_GEOM] & 0xFFFF, h = m[XCAP_META_GEOM] >> 16, cs = (m[XCAP_META_STATE] >> 1) & 7;
    printf("RX: locked after %.1f s: %ux%u %.3f Hz, colour %u, %u bit, flags %02x, audio %u00 Hz %u ch\n", double(qpc() - t0) / qpcFreq(), w, h, m[XCAP_META_RATE] / 1000.0, cs,
        (m[XCAP_META_STATE] >> 8) & 255, m[XCAP_META_FLAGS], m[XCAP_META_AUDIO] & 0xFFFF, (m[XCAP_META_AUDIO] >> 16) & 255);
    Sleep(1500);                                           // let the HDR infoframe arrive
    Config c; c.hdmi = true; c.width = w; c.height = h; c.pixfmt = cs == 0 ? XCAP_PIXFMT_BGRX8 : XCAP_PIXFMT_V210; c.audio = audio != 0; c.sliceLines = 36;
    if (!d.start(c)) { printf("START failed %lu\nFAIL\n", d.lastError()); return 1; }
    Clock ck; d.clock(ck);
    AudioCheck ac; if (audio) ac.start(d, ck, 0.004);
    const uint32_t S = d.slicesPerFrame();
    uint64_t f = 0, frames = 0, rep = 0, bad = 0, seqErr = 0, hdrFrames = 0; uint32_t lastSeq = 0, flags0 = 0, light0 = 0; std::vector<double> inter; int64_t lastQ = 0;
    const int64_t end = qpc() + int64_t(seconds * qpcFreq());
    while (qpc() < end) {
        if (d.waitSlices((f + 1) * S, 1000, 20) != Device::Wait::Ok) { printf("no frame for 1 s\n"); break; }
        const uint64_t newest = d.slicesDone() / S;
        if (newest > f + 2) { f = newest - 1; continue; }
        const auto* hd = d.header(f); const auto* tr = d.trailer(f);
        if (frames && hd->seq != lastSeq + 1) ++seqErr;
        lastSeq = hd->seq;
        if (tr->flags & XCAP_FRAME_BAD) ++bad;
        if (tr->flags & XCAP_FRAME_REPEAT) ++rep;
        if (hd->meta[XCAP_META_FLAGS] & 1) ++hdrFrames;
        if (!frames) { flags0 = hd->meta[XCAP_META_FLAGS]; light0 = hd->meta[XCAP_META_LIGHT]; }
        const int64_t q = qpc(); if (lastQ) inter.push_back(double(q - lastQ) * 1e6 / qpcFreq()); lastQ = q;
        ++frames; ++f;
    }
    ac.stop();
    d.stop();
    const double fps = inter.empty() ? 0 : 1e6 * inter.size() / [&] { double s = 0; for (double x : inter) s += x; return s; }();
    printf("video: %llu frames %.3f fps, bad %llu, sequence gaps %llu, identical to the previous %llu (colour bars do not move)\n", frames, fps, bad, seqErr, rep);
    printf("HDR in frame header: flags %02x (HDR %u BT.2020 %u EOTF %u) on %llu of %llu frames, MaxCLL %u MaxFALL %u\n", flags0, flags0 & 1, (flags0 >> 1) & 1, (flags0 >> 4) & 15, hdrFrames, frames, light0 & 0xFFFF, light0 >> 16);
    stat("frame interval", inter);
    bool ok = frames > seconds * 20 && !bad && !seqErr && rep + 2 >= frames;
    const bool wantHdr = mode == 0 || mode == 3;
    if (wantHdr) ok = ok && (flags0 & 0x23) == 0x23 && (light0 & 0xFFFF) == (hdr2 ? 3000u : 987u) && (light0 >> 16) == (hdr2 ? 800u : 321u);
    else ok = ok && !(flags0 & 1);
    if (audio) {
        printf("audio: packets %llu, words/s %.0f (want %u), gaps %llu, seq %llu, bad %llu, lost %llu\n", ac.packets, ac.rate(), (audio == 2 ? 8 : 2) * 48000u, ac.gaps, ac.seqErr, ac.bad, ac.lost);
        ok = ok && ac.packets && !ac.gaps && !ac.seqErr && !ac.bad && !ac.lost && std::abs(ac.rate() - (audio == 2 ? 8 : 2) * 48000.0) < 500;
    }
    printf("%s\n", ok ? "PASS" : "FAIL");
    return !ok;
}

// Record consecutive frames (v210) and the audio of a real source, for replay through the virtual card (XCAP_SIM clip= / pcm=).
// clip file: the first frame's 4 KB header (reserved1 = frame count) followed by the pixels of each frame.
static int cmdRecord(Device& d, uint32_t count, double audioSec, const char* clipFile, const char* audioFile) {
    uint32_t m[16]{};
    for (int i = 0; i < 16; ++i) d.read(XCAP_REG_HDMI0 + 4 * i, m[i]);
    const uint32_t w = m[XCAP_META_GEOM] & 0xFFFF, h = m[XCAP_META_GEOM] >> 16, cs = (m[XCAP_META_STATE] >> 1) & 7;
    if (!(m[XCAP_META_STATE] & 1) || !w || cs == 0) { printf("need a locked YCbCr signal (state %08x)\n", m[XCAP_META_STATE]); return 1; }
    Config c; c.hdmi = true; c.width = w; c.height = h; c.pixfmt = XCAP_PIXFMT_V210; c.audio = true; c.sliceLines = 36;
    SetPriorityClass(GetCurrentProcess(), HIGH_PRIORITY_CLASS);
    if (!d.start(c)) { printf("START failed %lu\n", d.lastError()); return 1; }
    const uint32_t S = d.slicesPerFrame(), bytes = d.dataBytes();
    std::vector<uint8_t> clip(size_t(XCAP_HDR_BYTES) + size_t(bytes) * count);
    std::atomic<bool> arun{true}; std::vector<uint32_t> araw; araw.reserve(size_t(audioSec * 400000) + 4096); uint64_t alost = 0;
    std::thread at([&] {
        uint64_t n = d.audioPackets();
        while (arun && araw.size() + XCAP_AUD_WORDS < araw.capacity()) {
            WaitForSingleObject(d.audioEvent(), 20);
            const uint64_t done = d.audioPackets();
            if (done > n + XCAP_AUD_RING - 8) { alost += done - n; n = done; }
            for (; n < done; ++n) { const auto* p = d.audioPacket(n); if (p->magic == XCAP_AUD_MAGIC && p->words <= XCAP_AUD_WORDS) araw.insert(araw.end(), p->word, p->word + p->words); }
        }
    });
    uint64_t f = d.slicesDone() / S + 2; uint32_t got = 0, lastSeq = 0, gaps = 0;
    while (got < count) {
        if (d.waitSlices((f + 1) * S, 1000, 20) != Device::Wait::Ok) { printf("no frame for 1 s\n"); break; }
        const auto* hd = d.header(f);
        if (got && hd->seq != lastSeq + 1) ++gaps;
        lastSeq = hd->seq;
        if (!got) memcpy(clip.data(), hd, XCAP_HDR_BYTES);
        memcpy(clip.data() + XCAP_HDR_BYTES + size_t(bytes) * got, d.pixels(f), bytes);
        if (!d.frameIntact(f) || (d.trailer(f)->flags & XCAP_FRAME_BAD)) { printf("frame %llu overwritten while copying\n", f); ++gaps; }
        ++got; ++f;
    }
    while (arun && araw.size() + XCAP_AUD_WORDS < araw.capacity()) Sleep(50);
    arun = false; at.join(); d.stop();
    reinterpret_cast<xcap_frame_header*>(clip.data())->reserved1 = got;
    if (FILE* o = fopen(clipFile, "wb")) { fwrite(clip.data(), 1, XCAP_HDR_BYTES + size_t(bytes) * got, o); fclose(o); }
    if (FILE* o = fopen(audioFile, "wb")) { fwrite(araw.data(), 4, araw.size(), o); fclose(o); }
    printf("recorded %u frames (%u gaps) %.2f GB, audio %zu words (%.1f s at 8 ch, %llu packets lost)\n", got, gaps, (XCAP_HDR_BYTES + double(bytes) * got) / 1e9, araw.size(), araw.size() / 384000.0, alost);
    return gaps || alost;
}

// Real HDMI source (PS5 etc.): capture, check the stream, save one frame and the audio.
static int cmdGrab(Device& d, double seconds, const char* frameFile, const char* audioFile, bool forceBgrx = false) {
    uint32_t m[16]{};
    for (int i = 0; i < 16; ++i) d.read(XCAP_REG_HDMI0 + 4 * i, m[i]);
    if (!(m[XCAP_META_STATE] & 1) || !(m[XCAP_META_GEOM] & 0xFFFF)) { printf("no HDMI signal (state %08x)\nFAIL\n", m[XCAP_META_STATE]); return 1; }
    const uint32_t w = m[XCAP_META_GEOM] & 0xFFFF, h = m[XCAP_META_GEOM] >> 16, cs = (m[XCAP_META_STATE] >> 1) & 7;
    printf("signal %ux%u %.3f Hz colour %u %u bit VIC %u, audio %u00 Hz %u ch format %u, changes %u\n", w, h, m[XCAP_META_RATE] / 1000.0, cs,
        (m[XCAP_META_STATE] >> 8) & 255, (m[XCAP_META_STATE] >> 16) & 255, m[XCAP_META_AUDIO] & 0xFFFF, (m[XCAP_META_AUDIO] >> 16) & 255, m[XCAP_META_AUDIO] >> 24, m[XCAP_META_CHANGES] & 0xFFFF);
    const uint32_t changes0 = m[XCAP_META_CHANGES] & 0xFFFF;
    Config c; c.hdmi = true; c.width = w; c.height = h; c.pixfmt = cs == 0 || forceBgrx ? XCAP_PIXFMT_BGRX8 : XCAP_PIXFMT_V210; c.audio = true; c.sliceLines = 36;
    SetPriorityClass(GetCurrentProcess(), HIGH_PRIORITY_CLASS);
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
    if (!d.start(c)) { printf("START failed %lu\nFAIL\n", d.lastError()); return 1; }
    Clock ck0; d.clock(ck0); Sleep(120); Clock ck; d.clock(ck);
    const double usPerTick = double(ck.qpc - ck0.qpc) * 1e6 / qpcFreq() / double(ck.ticks - ck0.ticks);
    auto toUs = [&](uint64_t ticks, int64_t q) { return double(q - ck.qpc) * 1e6 / qpcFreq() - double(int64_t(ticks - ck.ticks)) * usPerTick; };
    // audio: real programme material, so no sample-sequence check; count packets, keep levels, save the words
    std::atomic<bool> arun{true}; uint64_t apk = 0, awords = 0, aseq = 0, abad = 0, alost = 0, aBlk = 0; int32_t peak[8]{}; uint64_t chWords[8]{};
    std::vector<uint32_t> araw; araw.reserve(size_t(seconds * 1600000) + 4096);
    std::thread at([&] {
        SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
        uint64_t n = d.audioPackets(); uint32_t seq = 0; bool have = false;
        while (arun) {
            WaitForSingleObject(d.audioEvent(), 20);
            const uint64_t done = d.audioPackets();
            if (done > n + XCAP_AUD_RING - 8) { alost += done - n; n = done; have = false; }
            for (; n < done; ++n) {
                const xcap_audio_packet* p = d.audioPacket(n);
                if (p->magic != XCAP_AUD_MAGIC || p->words > XCAP_AUD_WORDS) { ++abad; continue; }
                if (have && p->seq != seq) ++aseq;
                seq = p->seq + 1; have = true; ++apk; awords += p->words;
                for (uint32_t i = 0; i < p->words; ++i) {
                    const uint32_t x = p->word[i]; const uint32_t ch = XCAP_AUD_CHANNEL(x);
                    const int32_t s = int32_t(XCAP_AUD_SAMPLE(x) << 8) >> 8;
                    peak[ch] = std::max(peak[ch], std::abs(s)); ++chWords[ch];
                    if (x & XCAP_AUD_BLOCK_START) ++aBlk;
                    if (araw.size() < araw.capacity()) araw.push_back(x);
                }
            }
        }
    });
    const uint32_t S = d.slicesPerFrame();
    uint64_t f = d.slicesDone() / S + 1, frames = 0, rep = 0, bad = 0, seqErr = 0, crcErr = 0, hdrErr = 0, disc = 0, overrun = 0, skipped = 0, hdrFrames = 0;
    uint32_t lastSeq = 0, flags0 = 0, light0 = 0, lum0 = 0, prim[4]{}; bool saved = false;
    std::vector<double> inter, lastLat; int64_t lastQ = 0;
    const int64_t t0 = qpc(), end = t0 + int64_t(seconds * qpcFreq());
    while (qpc() < end) {
        if (const uint64_t done = d.slicesDone() / S; done > f + 1) { skipped += done - f; f = done; }
        uint32_t crc[4] = { ~0u, ~0u, ~0u, ~0u };
        const uint32_t sliceBytes = d.stride() * c.sliceLines, total = d.dataBytes();
        auto wt = Device::Wait::Ok;
        for (uint32_t s = 0; s < S && wt == Device::Wait::Ok; ++s) {
            wt = d.waitSlices(f * S + s + 1, 1000, 20);
            if (wt == Device::Wait::Ok) { const uint32_t off = s * sliceBytes; crcLanes(d.pixels(f) + off, std::min(sliceBytes, total - off), crc); }
        }
        if (wt != Device::Wait::Ok) { printf("frame %llu: no data for 1 s (%s)\n", f, wt == Device::Wait::Timeout ? "timeout" : "stopped"); break; }
        const int64_t q = qpc();
        const xcap_frame_header hd = *d.header(f); const xcap_frame_trailer tr = *d.trailer(f);
        if (!d.frameIntact(f)) { ++overrun; ++f; continue; }
        if (hd.magic != XCAP_HDR_MAGIC || tr.magic != XCAP_TRL_MAGIC || tr.seq != hd.seq) ++hdrErr;
        if (frames && hd.seq != lastSeq + 1) ++seqErr;
        lastSeq = hd.seq;
        if (memcmp(crc, tr.crc, 16)) ++crcErr;
        if (tr.flags & XCAP_FRAME_BAD) ++bad;
        if (tr.flags & XCAP_FRAME_REPEAT) ++rep;
        if (hd.flags & XCAP_FRAME_DISCONT) ++disc;
        if (hd.meta[XCAP_META_FLAGS] & 1) ++hdrFrames;
        flags0 = hd.meta[XCAP_META_FLAGS]; light0 = hd.meta[XCAP_META_LIGHT]; lum0 = hd.meta[XCAP_META_MASTER_LUM];
        for (int i = 0; i < 4; ++i) prim[i] = hd.meta[XCAP_META_PRIM_GB + i];
        lastLat.push_back(toUs(tr.ts_last_pixel, q));
        if (lastQ) inter.push_back(double(q - lastQ) * 1e6 / qpcFreq()); lastQ = q;
        if (!saved && frameFile && q - t0 > 2 * qpcFreq() && !(tr.flags & XCAP_FRAME_BAD)) {
            std::vector<uint8_t> buf(XCAP_HDR_BYTES + total);
            memcpy(buf.data(), d.header(f), XCAP_HDR_BYTES); memcpy(buf.data() + XCAP_HDR_BYTES, d.pixels(f), total);
            if (d.frameIntact(f)) { if (FILE* o = fopen(frameFile, "wb")) { fwrite(buf.data(), 1, buf.size(), o); fclose(o); saved = true; } }
        }
        ++frames; ++f;
    }
    arun = false; at.join();
    uint32_t drop = 0, fbad = 0, aovf = 0; d.read(XCAP_REG_FRAMES_DROP, drop); d.read(XCAP_REG_FRAMES_BAD, fbad); d.read(XCAP_REG_AUD_OVERFLOW, aovf);
    d.stop();
    for (int i = 0; i < 16; ++i) d.read(XCAP_REG_HDMI0 + 4 * i, m[i]);
    const uint32_t changes = (m[XCAP_META_CHANGES] & 0xFFFF) - changes0;
    if (audioFile) if (FILE* o = fopen(audioFile, "wb")) { fwrite(araw.data(), 4, araw.size(), o); fclose(o); }
    const double fps = inter.empty() ? 0 : 1e6 * inter.size() / [&] { double s = 0; for (double x : inter) s += x; return s; }();
    const double secs = double(qpc() - t0) / qpcFreq();
    printf("video: %llu frames %.3f fps  unique %llu (%.2f fps)  saved frame %s\n", frames, fps, frames - rep, (frames - rep) / secs, saved ? frameFile : "no");
    printf("ERRORS  crc %llu  seq %llu  header/trailer %llu  bad %llu  discont %llu  overrun %llu  skipped %llu  fpga drop %u bad %u  signal changes %u\n",
        crcErr, seqErr, hdrErr, bad, disc, overrun, skipped, drop, fbad, changes);
    printf("HDR: flags %02x (infoframe %u BT.2020 %u full %u EOTF %u) on %llu/%llu frames  MaxCLL %u MaxFALL %u  mastering max %u min %u  primaries %08x %08x %08x %08x\n",
        flags0, flags0 & 1, (flags0 >> 1) & 1, (flags0 >> 2) & 1, (flags0 >> 4) & 15, hdrFrames, frames, light0 & 0xFFFF, light0 >> 16, lum0 & 0xFFFF, lum0 >> 16, prim[0], prim[1], prim[2], prim[3]);
    printf("audio: packets %llu  words/s %.0f  seq %llu  bad %llu  lost %llu  overflow %u  block starts %llu\n", apk, awords / secs, aseq, abad, alost, aovf, aBlk);
    printf("  peak dBFS per channel:");
    for (int i = 0; i < 8; ++i) printf(" %d:%s", i, chWords[i] ? (peak[i] ? std::to_string(int(std::lround(20 * std::log10(peak[i] / 8388608.0)))).c_str() : "-inf") : "none");
    printf("\n");
    stat("LAST pixel -> whole frame seen", lastLat);
    stat("frame interval", inter);
    const bool ok = frames > secs * 50 && !crcErr && !seqErr && !hdrErr && !bad && !disc && !overrun && !changes && apk && !aseq && !abad && !alost && !aovf;
    printf("%s\n", ok ? "PASS" : "FAIL");
    return !ok;
}

int main(int argc, char** argv) {
    const std::string cmd = argc > 1 ? argv[1] : "info";
    Device d;
    if (cmd == "edid" && argc > 3 && !_stricmp(argv[2], "file")) {   // edid file <tv edid.bin> [apply]: as "edid tv", from a saved TV EDID
        std::vector<uint8_t> b; if (FILE* fi = fopen(argv[3], "rb")) { uint8_t t[1024]; b.assign(t, t + fread(t, 1, sizeof t, fi)); fclose(fi); }
        if (b.size() < 256) { printf("cannot read %s\n", argv[3]); return 1; }
        AudioCaps pc; pc.ac3 = pc.eac3 = pc.mat = pc.dts = pc.dtsHd = true;
        const auto t = parseTv(b);
        printf("%s: HDR %d, PCM %u ch, Atmos E-AC-3 %d, MAT %d, audio formats %zu\n", argv[3], t.hdr, t.pcmChannels, t.atmosEac3, t.atmosMat, t.sads.size());
        const auto e = composeEdid(t, pc);
        for (int i = 0; i < 256; ++i) printf("%02x%s", e[i], i % 32 == 31 ? "\n" : "");
        printf("number %u\n", edidNumber(e));
        if (argc > 4) { bool ch = false; const bool ok = d.open(L"") && applyEdid(d, e, &ch); printf("apply %s%s\n", ok ? "ok" : "FAILED", ch ? "" : " (already active)"); return !ok; }
        return 0;
    }
    if (cmd == "edid" && argc > 2 && !_stricmp(argv[2], "tv")) {   // edid tv [apply]: what the HDMI source will be told
        AudioCaps pc; pc.ac3 = pc.eac3 = pc.mat = pc.dts = pc.dtsHd = true;      // Veyra narrows this down to what Windows can play out
        std::array<uint8_t, 256> e{}; bool have = false;
        const auto monitors = activeMonitors(); const TvEdid* tv = chooseTv(monitors);
        for (const auto& m : monitors) {
            const auto t = parseTv(m.bytes);
            printf("%s%ls: EDID %zu bytes, HDR %d, peak %.0f nit, frame average %.0f nit, PCM %u ch, Atmos E-AC-3 %d, MAT %d, audio formats %zu\n", &m == tv ? "* " : "  ", m.name.c_str(), m.bytes.size(), t.hdr,
                t.maxLum ? 50 * pow(2, t.maxLum / 32.0) : 0.0, t.avgLum ? 50 * pow(2, t.avgLum / 32.0) : 0.0, t.pcmChannels, t.atmosEac3, t.atmosMat, t.sads.size());
            if (&m == tv) { e = composeEdid(t, pc); have = true; }
        }
        if (!have) { printf("no active monitor with an EDID\n"); return 1; }
        for (int i = 0; i < 256; ++i) printf("%02x%s", e[i], i % 32 == 31 ? "\n" : "");
        printf("number %u\n", edidNumber(e));
        if (argc > 3) { bool ch = false; const bool ok = d.open(L"") && applyEdid(d, e, &ch); printf("apply %s%s\n", ok ? "ok" : "FAILED", ch ? "" : " (already active)"); return !ok; }
        return 0;
    }
    if (!d.open(L"")) { printf("open failed %lu\n", d.lastError()); return 2; }
    if (cmd == "info") return cmdInfo(d);
    if (cmd == "clock") { for (int i = 0; i < 5; ++i) { Clock c; d.clock(c); printf("ticks %llu qpc %lld +-%.2f us\n", c.ticks, c.qpc, c.errorQpc * 1e6 / qpcFreq()); Sleep(100); } return 0; }
    if (cmd == "hdmi") {
        uint32_t m[16]{}; for (int i = 0; i < 16; ++i) d.read(XCAP_REG_HDMI0 + 4 * i, m[i]);
        if (!m[XCAP_META_FW] || m[XCAP_META_FW] == ~0u) { printf("no HDMI firmware on the card\n"); return 1; }
        const char* cs[] = { "RGB", "4:2:2", "4:4:4", "4:2:0", "?", "?", "?", "?" };
        uint32_t beat = m[XCAP_META_BEAT]; Sleep(200); d.read(XCAP_REG_HDMI0 + 4 * XCAP_META_BEAT, m[XCAP_META_BEAT]);
        printf("firmware %08x  %s  heartbeat %s\n", m[XCAP_META_FW], (m[XCAP_META_STATE] & 1) ? "LOCKED" : "no signal", m[XCAP_META_BEAT] != beat ? "running" : "STOPPED");
        printf("%ux%u  %.3f Hz  %s %u bit  VIC %u  flags %02x (HDR %u, BT.2020 %u, full %u, EOTF %u)\n", m[9] & 0xFFFF, m[9] >> 16, m[8] / 1000.0, cs[(m[10] >> 1) & 7], (m[10] >> 8) & 255, (m[10] >> 16) & 255,
            m[0], m[0] & 1, (m[0] >> 1) & 1, (m[0] >> 2) & 1, (m[0] >> 4) & 15);
        { uint32_t a = m[XCAP_META_AUDIO], st = m[XCAP_META_STATE]; printf("audio %u00 Hz  %u ch  format %u  EDID %s", a & 0xFFFF, (a >> 16) & 255, a >> 24, (st & 32) ? "from host" : (st & 16) ? "Atmos" : "PCM");
          if (st & 32) printf(" #%u", st >> 24);
          if (m[XCAP_META_FW] >= 0x30000u) printf("   HDMI card %s, source 5V %s", (st & 64) ? "found" : "NOT FOUND", (st & 128) ? "on" : "off");
          printf("\n"); }
        printf("MaxCLL %u MaxFALL %u mastering max %u  refclk %u kHz  changes %u  errors %08x\n", m[7] & 0xFFFF, m[7] >> 16, m[6] & 0xFFFF, m[15], m[11] & 0xFFFF, m[12]);
        { const uint32_t tx = m[11] >> 16; uint32_t ctl = 0; d.read(XCAP_REG_TX_CTRL, ctl);
          const char* what = ((tx >> 4) & 15) == 0xE ? "LOOP-OUT running" : (tx & 0x10) ? "test pattern" : (ctl & 0x400) ? "loop-out off (host)" : "loop-out waiting";
          printf("HDMI OUT: %s, sink %s, stream %s, clock chip %s, starts %u\n", what, (tx & 1) ? "connected" : "none", (tx & 2) ? "up" : "down",
              (tx & 8) ? "FAILED" : (tx & 4) ? "ok" : "?", (tx >> 8) & 255); }
        return 0;
    }
    if (cmd == "meta") { // signal description for the test pattern: meta hdr | meta sdr
        const bool hdr = argc > 2 && std::string(argv[2]) == "hdr";
        // HDR infoframe present, BT.2020, EOTF 2 (PQ); P3 primaries, 1000 nit mastering, MaxCLL 987, MaxFALL 321
        const uint32_t m[8] = { hdr ? 0x23u : 0u, 13250u | 34500u << 16, 7500u | 3000u << 16, 34000u | 16000u << 16, 15635u | 16450u << 16, 0, hdr ? 1000u | 1u << 16 : 0u, hdr ? 987u | 321u << 16 : 0u };
        bool ok = true; for (uint32_t i = 0; i < 8; ++i) ok &= d.write(XCAP_REG_META0 + 4 * i, m[i]);
        printf("test pattern metadata %s %s\n", hdr ? "HDR10" : "SDR", ok ? "ok" : "FAILED"); return ok ? 0 : 1;
    }
    if (cmd == "edid" && argc > 2) {            // forces the list of formats shown to the HDMI source until Veyra or a reset changes it
        const bool atmos = !_stricmp(argv[2], "atmos"); uint32_t v = 0, st = 0;
        d.read(XCAP_REG_HOST_CTRL, v); v = (v & ~0xFF30u) | (atmos ? 16u : 0u);
        if (!d.write(XCAP_REG_HOST_CTRL, v)) { printf("write failed %lu\n", d.lastError()); return 1; }
        for (int i = 0; i < 30; ++i) { Sleep(100); d.read(XCAP_REG_HDMI0 + 4 * 10, st); if ((st & 48) == (atmos ? 16u : 0u)) break; }
        const bool ok = (st & 48) == (atmos ? 16u : 0u); printf("EDID now %s  %s\n", (st & 32) ? "from host" : (st & 16) ? "Atmos" : "PCM", ok ? "ok" : "FAILED"); return !ok;
    }
    if (cmd == "loopout" && argc > 2) {   // loopout on | off | force (as on, but without a sink: for link captures)
        const uint32_t v = !strcmp(argv[2], "off") ? XCAP_TX_LOOPOUT_OFF : !strcmp(argv[2], "force") ? XCAP_TX_FORCE_CONNECTED : 0u;
        if (!d.write(XCAP_REG_TX_CTRL, v)) { printf("write failed %lu\n", d.lastError()); return 1; }
        printf("loop-out %s\n", argv[2]); return 0;
    }
    if (cmd == "tx" && argc > 2 && !strcmp(argv[2], "off")) { d.write(XCAP_REG_TX_CTRL, 0); printf("TX off\n"); return 0; }
    if (cmd == "hpd") {   // hpd [ms]: pulse the HDMI IN hot plug low, the source re-reads the EDID and restarts the link
        const DWORD ms = argc > 2 ? DWORD(atoi(argv[2])) : 2000; uint32_t v = 0, st = 0;
        if (!d.read(XCAP_REG_HOST_CTRL, v)) { printf("read failed %lu\n", d.lastError()); return 1; }
        d.write(XCAP_REG_HOST_CTRL, v | 1u); Sleep(ms); d.write(XCAP_REG_HOST_CTRL, v & ~1u);
        bool locked = false;
        for (int i = 0; i < 100 && !locked; ++i) { Sleep(100); d.read(XCAP_REG_HDMI0 + 4 * XCAP_META_STATE, st); uint32_t g = 0; d.read(XCAP_REG_HDMI0 + 4 * XCAP_META_GEOM, g); locked = (st & 1) && (g & 0xFFFF); }
        printf("hot plug pulsed %lu ms, source %s\n", ms, locked ? "locked again" : "NOT back after 10 s");
        return !locked;
    }
    if (cmd == "record" && argc > 5) return cmdRecord(d, uint32_t(atoi(argv[2])), atof(argv[3]), argv[4], argv[5]);
    if (cmd == "grab") return cmdGrab(d, argc > 2 ? atof(argv[2]) : 10, argc > 3 ? argv[3] : nullptr, argc > 4 ? argv[4] : nullptr, argc > 5 && !strcmp(argv[5], "bgrx"));
    if (cmd == "loop") return cmdLoop(d, argc > 2 ? atoi(argv[2]) : 0, argc > 3 ? atoi(argv[3]) : 1, argc > 4 ? atof(argv[4]) : 10, argc > 5 && atoi(argv[5]) != 0);
    if (cmd == "reg" && argc > 2) { uint32_t v = 0; d.read(strtoul(argv[2], 0, 0), v); printf("%08x\n", v); return 0; }
    if (cmd == "run") {
        const double sec = argc > 2 ? atof(argv[2]) : 5;
        const uint32_t fmt = argc > 3 && std::string(argv[3]) == "bgrx" ? XCAP_PIXFMT_BGRX8 : XCAP_PIXFMT_V210;
        const uint32_t lines = argc > 4 ? atoi(argv[4]) : 72, spin = argc > 5 ? atoi(argv[5]) : 0;
        const double hz = argc > 6 ? atof(argv[6]) : 60;
        return cmdRun(d, sec, fmt, lines, spin, hz, argc > 7 ? strtoul(argv[7], 0, 0) : 0);
    }
    if (cmd == "kill") { // start and die without stopping: the driver must clean up
        Config c; if (!d.start(c)) { printf("START failed %lu\n", d.lastError()); return 1; }
        Sleep(200); TerminateProcess(GetCurrentProcess(), 99);
    }
    if (cmd == "cycle") { // start/stop stress
        int n = argc > 2 ? atoi(argv[2]) : 20, fail = 0;
        for (int i = 0; i < n; ++i) {
            Config c; c.pixfmt = i & 1; c.slots = 2 + i % 5; c.audio = (i % 3) == 1;
            if (!d.start(c)) { printf("START %d failed %lu\n", i, d.lastError()); ++fail; break; }
            auto w = d.waitSlices(uint64_t(d.slicesPerFrame()) * 3, 1000);
            const bool ok = w == Device::Wait::Ok && d.header(1)->magic == XCAP_HDR_MAGIC && d.trailer(1)->magic == XCAP_TRL_MAGIC && d.header(1)->seq == d.trailer(1)->seq && d.ctl()->align_errors == 0 && d.ctl()->state == 1;
            if (!ok) { printf("cycle %d: wait %d hdr %08x trl %08x align %u state %u status %08x\n", i, int(w), d.header(1)->magic, d.trailer(1)->magic, d.ctl()->align_errors, d.ctl()->state, d.ctl()->engine_status); ++fail; }
            d.stop();
        }
        xcap_info inf{}; d.info(inf);
        printf("%d cycles, %d failed, stuck %u\n%s\n", n, fail, inf.engine_stuck, fail || inf.engine_stuck ? "FAIL" : "PASS");
        return fail;
    }
    return 2;
}
