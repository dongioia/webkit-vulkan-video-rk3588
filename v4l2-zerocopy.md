# A second path: zero-copy in the browser, all four codecs, no Vulkan

The Vulkan Video route in the main README works, but it copies the decoded frame through system memory on its way to the screen. While chasing that copy I tried a different route into the same browser, and it turned out to do more than I expected: zero-copy, and all four codecs the chip can decode — H.264, HEVC, VP9 and AV1.

This route does not use Vulkan Video at all. It uses the kernel's V4L2 stateless decoders directly — the same rkvdec path mpv and GStreamer already use — and wraps them so WebKitGTK will accept their hardware buffers.

## The one thing in the way

WebKitGTK decodes through GStreamer's `decodebin`, which can already pick the kernel decoders (`v4l2slh264dec` and friends). So in principle a browser on this chip could hardware-decode out of the box. In practice it errors out, and the reason is a single caps-negotiation detail.

`v4l2codecs` refuses to hand out its hardware dmabuf unless the element downstream advertises the `GstVideoMeta` API in its allocation query. The hardware buffers are padded — stride is wider than the picture, coded height taller than the visible height — so the meta is how the real layout travels. WebKit's GL video sink negotiates the dmabuf fine, but it does not advertise `GstVideoMeta`, so the decoder aborts:

```
gstv4l2codech264dec.c: decide_allocation:
    DMABuf caps negotiated without the mandatory support of VideoMeta
```

The pipeline goes not-negotiated and the `<video>` element fails with `MEDIA_ERR_SRC_NOT_SUPPORTED`. No picture, no software fallback in some configurations — just a dead video element.

WebKit is not actually missing anything here: its registry scanner lists every decoder it finds, and its sink negotiates DMA-BUF and the modifier-aware DMA_DRM form perfectly well. It just does not put `GstVideoMeta` in the allocation query, and the kernel decoder treats that as mandatory.

## The fix

A small GStreamer element that wraps each V4L2 stateless decoder and injects `GstVideoMeta` into the allocation query as it passes through. That is the whole idea. The dmabuf itself is never touched — it goes straight from rkvdec to WebKit's compositor, which imports it through EGLImage like any other dmabuf. Zero-copy.

The element registers one bridge per codec at rank 258, just above the plain decoders at 257, so `decodebin` auto-plugs the wrapper instead of the bare decoder. No WebKit patch, no environment beyond a plugin path.

## What works

I tested in Epiphany (WebKitGTK 2.52) on a Radxa Rock 5B+, kernel 7.1, Mesa 26.0.6, sway.

- H.264: hardware decode on rkvdec, the NV12 dmabuf reaches WebKit's compositor with no copy. Clean.
- HEVC: the same idea, second codec on rkvdec, zero-copy, clean. Big Buck Bunny in HEVC plays in the browser.
- AV1: hardware decode on the RK3588's separate AV1 block, a Hantro decoder on `/dev/video4` distinct from rkvdec, zero-copy, clean. This one needs a kernel that actually carries the AV1 stateless driver; it is not in every build.
- VP9: hardware decode on rkvdec, zero-copy, clean, but only after forcing 8-bit NV12 output. Left to itself the decoder picks a 10-bit packed format (NV15) for an 8-bit clip, and WebKit's EGL cannot import NV15, so you get green tiles. The bridge pins NV12 for VP9 to avoid that.

One thing had to be fixed for all of them: a band along the very bottom of the picture (green on VP9, shifting colour on AV1). The v4l2 decoders put the *coded* height in the buffer's GstVideoMeta (VP9 768 for a visible 720, H.264 1088 for 1080), and WebKit renders that height, so the padding rows below the picture get scanned out. Per the GstVideoMeta convention the height field is the display height and the padding lives in the plane offsets, which the decoder already sets correctly, so the bridge simply lowers the meta height to the visible height and WebKit crops the band. The dmabuf is untouched, so it stays zero-copy. AV1's band was a different thing, the tiled `NV12_4L4` output's edge tiles; forcing linear NV12 (below) plus the same crop clears it.

Two details I had to get right beyond the meta injection, both for VP9 and AV1. First, frame alignment: these two stateless decoders only accept frame-aligned input, and without pinning `alignment=frame` the parser offers tu/obu/super-frame alignment, the decoder refuses the caps, and the browser quietly falls back to software. Pinning frame alignment is what got either codec onto the hardware at all. Second, the VP9 NV12 constraint above.

For comparison, the VP9 green here is not the one Chromium hit. Chromium's VP9 problem was a GPU colour-conversion bug on correct 8-bit NV12. This one sits upstream of the GPU entirely, the decoder choosing a 10-bit output for 8-bit content, and the fix is a format constraint rather than a CPU-copy workaround, so it stays zero-copy.

## What I did not verify

- One board: Rock 5B+, the versions above. I do not know how it behaves elsewhere.
- VP8 and MPEG-2: the element registers bridges for them too, because the rkvdec V4L2 driver exposes those decoders, but I have no test clips, so they are untested. Treat them as unproven.
- VP9 logs a couple of non-fatal "device or resource busy" REQBUFS warnings at startup on the shared rkvdec device. The picture is still clean; I have not chased the warnings down.
- AV1 logs a few "end picture error" warnings, three frames on a short clip. The picture is still clean, but I have not run them to ground.
- Correctness in the browser is visual: the picture is right. It is not byte-checked through the compositor. The standalone decode is byte-exact against ffmpeg (the corpus in the main README, same kernel decoder).

## Real YouTube, tested by hand

I did sit down and drive the live site, and it is worth being precise about what happened, because it is a mix of a real result and real rough edges.

The good part: on actual youtube.com, both AV1 and VP9 hardware-decode through this bridge, zero dropped frames, at 360p, 720p and 1080p.

The rough edges, all of which live in the present path (WebKit's compositor and Mesa), not in the bridge or the decode:

- You need a bigger CMA pool or it falls over. Zero-copy means the browser holds the actual hardware (CMA) buffers, and the decoder allocates more of them on the fly as the browser holds frames in flight. The default 64 MB CMA runs out within a minute or two of playback; the kernel then floods `cma: alloc failed` / `dma alloc of size … failed`, Mesa throws `drmPrimeHandleToFD() failed`, and the browser — or the whole board — locks up. Booting with `cma=512M` (kernel command line) makes the exhaustion and the freeze go away. This is a requirement, not a nice-to-have. See build notes below.
- 480p and 240p go black, with a `MESA: error: WSI pitch not properly aligned` flood. Here is the mechanism, traced: those widths are 854 and 426, and the decoder pads the stride to a multiple of 16 (854 becomes a 864-byte stride). WebKit/Mesa's dmabuf import wants the pitch aligned to 64, and 864 is not (864 mod 64 = 32), so the import fails and the frame is black. 360p (640), 720p (1280) and 1080p (1920) all give a 64-aligned stride and are fine. It is the *import* that fails, not the present: it happens windowed as well as full-screen. The stride is fixed by the kernel driver (rkvdec/hantro align to 16), so the bridge cannot make it 64-aligned without re-laying-out the pixels, i.e. a copy. The clean fix is on the WebKit/Mesa side (the import is handed the stride explicitly and should accept it); a local workaround would re-stride only the non-64-aligned widths through a copy, keeping 360p/720p/1080p zero-copy. For now: use 720p or 1080p.
- Closing a tab can crash the browser (it restarts and reopens the tabs). On teardown Mesa logs `drmPrimeHandleToFD() failed (err=22)` and then a `g_close()` on a garbage fd with `EBADF`. This is a dmabuf-fd lifecycle bug on the MSE/teardown path; it does not happen on a plain local `<video>`, only with YouTube's Media Source path.

So the honest one-liner: YouTube's AV1 and VP9 do hardware-decode here with `cma=512M`, the picture is clean, but 480p/240p are still broken and the MSE teardown is not stable. Usable to watch a 720p/1080p video, not production.

## How it relates to the Vulkan path

This is the route that works in a browser today, zero-copy, for every codec the chip decodes. It is not Vulkan Video — it is the kernel V4L2 stateless path, wrapped so a browser will take it.

The Vulkan Video driver is still the longer bet, because that is the direction upstream browsers are heading and the V4L2-in-Chromium path is a downstream fork. Making the Vulkan path itself zero-copy is separate work, still in progress. The element here is the practical answer in the meantime.

## Build and use

```sh
make libgstv4l2metabridge.so          # needs gstreamer-video-1.0
export GST_PLUGIN_PATH=$PWD:$GST_PLUGIN_PATH
gst-inspect-1.0 | grep metabridge     # v4l2{h264,h265,vp8,vp9,mpeg2,av1}metabridge
```

Then run WebKitGTK with that `GST_PLUGIN_PATH`. The bridges register above the plain decoders, so `decodebin` plugs them automatically; there is nothing else to set.

For anything beyond a short clip — and for YouTube in particular — boot with a larger CMA pool, or it will run the contiguous-memory pool dry and lock up:

```sh
# add to the kernel command line (e.g. GRUB_CMDLINE_LINUX_DEFAULT), then reboot
cma=512M
# verify after boot:
grep CmaTotal /proc/meminfo   # should read ~524288 kB
```
