# WebKit hardware video decode through Vulkan Video on the RK3588

I got the GNOME Web browser (WebKitGTK / Epiphany) to hardware-decode H.264, and now HEVC, on a Rockchip RK3588 board by routing it through a standalone Vulkan Video driver, with no patch to WebKit itself. This repository holds the small GStreamer bridge elements that make it work, plus what you need to reproduce it.

## Why I did this

Hardware video decode in a browser on the RK3588 has been a dead end for a while. The V4L2 path that mpv and GStreamer use is rejected upstream by Chromium, so it only survives in a downstream fork. Firefox has no working mainline-V4L2 path at all. There is no VA-API driver for the chip. Vulkan Video, meanwhile, is the direction the desktop GPU stacks are taking, so it seemed like the thing to bet on. I wanted to find out whether a Vulkan Video driver could feed a real browser today, on this hardware.

It can.

## What works, and what doesn't

This is a proof of concept, so I want to be precise about what I actually verified.

H.264, the original result:

- Real hardware decode, byte-exact against an ffmpeg reference at 360p through 1080p, cropped sizes included.
- Plays in Epiphany, including a clip pulled off YouTube, with rkvdec busy the whole time and no software fallback. The video keeps playing, not just a frozen first frame.
- Nothing in WebKit was patched. The only moving parts are an out-of-tree GStreamer plugin and two environment variables.

HEVC, added afterwards:

- Same idea, second codec. The driver decodes HEVC Main 8-bit on rkvdec, byte-exact against ffmpeg across a corpus I built to exercise the parser rather than just the geometry: 640×360 (cropped), 1280×720 and 1920×1080, each as I-only, P and B-frame variants, plus a longer-GOP clip with more than one short-term reference-picture set. Ten clips, all byte-exact.
- It plays in Epiphany on both paths, a plain `<video>` tag and Media Source Extensions (what a streaming site uses): rkvdec busy, the bridge plugged, no software HEVC decoder, backward seek clean.
- A clip I did not encode myself, Big Buck Bunny in HEVC from test-videos.co.uk (300 frames of I/P/B), decodes byte-exact and plays in the browser too.

What the HEVC path does not cover, and I want to be exact about this:

- Main profile, 8-bit, 4:2:0 only. No 10-bit, which means no Main10 and no HDR; a 10-bit stream will not use this path and falls back to software. No 4:2:2 or 4:4:4, no range extensions.
- Weighted prediction is not parsed. A clip that uses it (some fades and dissolves do) may decode wrong.
- Long-term references are not handled, and this one is a known bug, not just an untested case. The encoder I used (x265) does not emit long-term references, so I could not test them end to end; and the code that marks a decoded picture as a long-term reference still reads the H.264 side's flag, which is never set on the HEVC path. So a stream that uses long-term references may decode wrong. If you have one, I would like a copy.
- YouTube, by the way, does not serve HEVC at all (it uses VP9, AV1 and H.264), so there is no YouTube-HEVC test to run here.

The caveats that apply to both codecs:

- I tested on one board: a Radxa Rock 5B+, kernel 7.1, Mesa 26.0.6, sway. I do not know how it behaves elsewhere, which is part of why I am publishing this.
- The decode-to-display path copies through system memory. There is no zero-copy yet (more on that below).
- The byte-exact checks are on the standalone decode. In-browser correctness is confirmed visually (the picture is right), not byte-checked through the browser compositor.
- The bridge elements are proof of concept, not production code.

## A second path that is zero-copy, and covers all four codecs

While chasing the system-memory copy above, I tried a different route into the same browser that does not go through Vulkan at all. It wraps the kernel's V4L2 stateless decoders directly and gets WebKit to take their hardware dmabuf with no copy, for H.264, HEVC, VP9 and AV1. It needs one small GStreamer element and no WebKit patch. On real youtube.com, AV1 and VP9 hardware-decode this way at 360p, 720p and 1080p with zero dropped frames.

It is not finished, and the rough edges are honest and specific: it needs a larger CMA pool (`cma=512M`) or sustained playback exhausts memory and locks up; there is a colour band along the bottom of the picture (coded padding the present path does not crop); 480p and 240p go black on a pitch-alignment wall; and closing a YouTube tab can crash the browser on the Media Source teardown. All of those live in WebKit and Mesa's present path, not in the decode. The write-up, the full caveats, the `cma=512M` requirement, and `gstv4l2metabridge.c` are in [v4l2-zerocopy.md](v4l2-zerocopy.md).

The Vulkan path in the rest of this README is still the longer bet for upstream browsers. The V4L2 route is what decodes every codec the chip handles in a browser today; the present-path rough edges above are the work between here and something you would call finished.

## How it works

The Vulkan Video decoder, `vulkanh264dec`, hands frames out as `memory:VulkanImage`. WebKit's GStreamer auto-plugger, `decodebin`, treats that opaque memory type as a dead end and will not insert a converter, so it falls back to software. The `vulkandownload` element can turn VulkanImage into plain system memory, but decodebin will not chain it in on its own.

So I wrote a tiny GStreamer bin, `vkh264bridge`, that wraps `vulkanh264dec ! vulkandownload` and presents itself to decodebin as an ordinary H.264 decoder with a plain `video/x-raw` NV12 output. decodebin then picks it like any other decoder, and the Vulkan context is shared internally between the two wrapped elements. That is the whole trick.

HEVC works the same way. `vkh265bridge` wraps `vulkanh265dec ! vulkandownload` with `video/x-h265` in and NV12 out. The only real difference is on the Media Source path: WebKit uses `decodebin3` there, which does not back out of a dead-end decoder the way `decodebin` does, so the bridge has to outrank the raw `vulkanh265dec` for `decodebin3` to pick it. Both bridges set rank 258 and demote the raw element, which covers both paths.

## Installing the Vulkan Video driver (the real prerequisite)

Everything here rides on a Vulkan Video driver for the rkvdec hardware, and there is no packaged one yet. It is the experimental V4L2-backed Vulkan Video ICD from Sreerenj Balachandran's RFC ([Mesa issue #14987](https://gitlab.freedesktop.org/mesa/mesa/-/issues/14987), commit `5955e6e` on his `v4l2-vulkan-video` branch), plus a small init-sequence fix I found and reported there ([note 3528237](https://gitlab.freedesktop.org/mesa/mesa/-/work_items/14987#note_3528237)). Without that fix the hardware decodes a blank frame, so it is not optional.

You build it from source. This is the path I used.

Get Sreerenj's Mesa fork and check out the prototype:

```sh
git clone https://gitlab.freedesktop.org/sree/mesa.git
cd mesa
git checkout 5955e6eb0a03fdd0804b9b3ecf98d8681187c189   # the v4l2-vulkan-video branch
```

Apply the two patches from this repo's `icd/` directory:

```sh
git apply /path/to/icd/compat-mesa26.patch       # lets the ~3-month-old prototype build against Mesa 26.x
git apply /path/to/icd/b0-fix.patch              # the init-SPS fix; without it the decode is blank
git apply /path/to/icd/s3-readback-stride.patch  # the row-stride fix; without it, non-720p frames tear
```

Build and install. The meson line is the prototype author's own (from its `ARCHITECTURE.txt`); change `platforms`, `gallium-drivers` and the prefix to suit your machine:

```sh
meson setup builddir -Dvulkan-drivers=v4l2-video -Dgallium-drivers=panfrost \
  -Dvulkan-beta=true -Dplatforms=x11 -Dglx=dri -Degl=enabled -Dgbm=enabled \
  -Dvideo-codecs=all --prefix=$HOME/mesa-v4l2-vulkan
ninja -C builddir
ninja -C builddir install
```

Point Vulkan at the driver and check it loaded:

```sh
export VK_ICD_FILENAMES=$HOME/mesa-v4l2-vulkan/share/vulkan/icd.d/v4l2vk_icd.aarch64.json
vulkaninfo | grep -i v4l2   # the "V4L2 Vulkan Video Decoder" device should appear
```

`ninja install` writes both the library and the ICD manifest under your prefix; there is a copy of the manifest in `icd/` for reference. I built against Mesa 26.1-devel on aarch64 (Arch ARM). Once `vulkaninfo` lists the decoder, the bridge below can use it.

## The fix I added (`icd/b0-fix.patch`)

The prototype set the H.264 SPS control only on each decode request, never once at session init. The rkvdec stateless decoder wants the SPS as a plain non-request control before the CAPTURE format and buffers are set up. Without it the decoder stays unconfigured and writes a blank frame, even though the per-request controls are byte-identical to the in-tree `v4l2slh264dec` that decodes the same clip correctly. I found this by diffing the two drivers' `S_EXT_CTRLS` traces.

So the fix sets the SPS non-request at init, right after `S_FMT(OUTPUT)` and before CAPTURE setup, and reads the driver's native CAPTURE format instead of forcing one:

```c
/* in session init, before set_capture_format(): */
if (sps && pps) {
    v4l2vk_h264_translate_sps_pps(sps, pps, &init_params);
    v4l2vk_v4l2_set_init_sps(sess->v4l2_ctx, &init_params);   /* S_EXT_CTRLS, which = CUR_VAL */
}

/* inside v4l2vk_v4l2_set_init_sps(): */
ext.which = V4L2_CTRL_WHICH_CUR_VAL;            /* non-request */
xioctl(ctx->video_fd, VIDIOC_S_EXT_CTRLS, &ext);
```

The whole change is `icd/b0-fix.patch` (7 files). I reported it on [Mesa #14987](https://gitlab.freedesktop.org/mesa/mesa/-/work_items/14987#note_3528237). With it, the output is byte-exact against ffmpeg on baseline, High-with-B-frames, multi-slice, and cropped streams.

## A second fix: row stride (`icd/s3-readback-stride.patch`)

After the first version went up, I tried a real clip at 360p and the picture fell apart: the frame tiled itself sideways with a green band along the bottom. Still real hardware decode, just the pixels in the wrong places.

It was a row-stride mismatch in the readback. When the driver copies a decoded NV12 frame out of the Vulkan image into system memory, it took the row length as the width rounded up to 256. Everywhere else it uses the width rounded up to 16, which is the stride the kernel actually hands back: when it creates the image, when it copies the hardware buffer in, when it reports the layout. Those two only agree when the width is already a multiple of 256. 1280 is, so my first tests at 1280×720 came out byte-exact and the bug stayed hidden. 640 is not. The readback walked each row at a pitch of 768 while the data sat at 640, so every row slid 128 bytes and the image tore.

The fix takes the stride from the image's own stored plane offset, so it matches the real layout at any width. With it the output is byte-exact at 360p, 720p and 1080p, cropped heights included, and that real YouTube clip plays cleanly in Epiphany. Like the init-SPS fix, it is small enough to belong upstream on the same Mesa #14987 thread.

## Reproduce it

You will need:

- An RK3588 board with a mainline kernel that exposes rkvdec (V4L2 stateless H.264 and HEVC).
- GStreamer 1.28 or newer, with the `vulkan` and `v4l2codecs` plugins.
- The Vulkan Video V4L2 ICD above, deployed and enumerating.
- For HEVC, the ICD also needs the HEVC decode support I added on top of the same prototype. It is not in the upstream prototype yet, so I am offering it on the same Mesa #14987 thread; until it lands there the driver advertises H.264 only. Ask me if you want to try it before then.

Build the bridge:

```sh
make
```

Point GStreamer at it and at the ICD. Nothing is installed system-wide:

```sh
export GST_PLUGIN_PATH=$PWD:$GST_PLUGIN_PATH
export VK_ICD_FILENAMES=$HOME/mesa-v4l2-vulkan/share/vulkan/icd.d/v4l2vk_icd.aarch64.json   # the one ninja install made, not the bundled icd/ copy
rm -f ~/.cache/gstreamer-1.0/registry.aarch64.bin   # so the vulkan plugin re-registers with the ICD
gst-inspect-1.0 vkh264bridge                          # should show rank 258
```

Quick decode check:

```sh
gst-launch-1.0 filesrc location=sample.h264 ! h264parse ! vkh264bridge ! fakesink
```

For HEVC, build `vkh265bridge` the same way (`make` builds both) and check it the same way, once the HEVC-capable ICD is in place:

```sh
gst-inspect-1.0 vkh265bridge                          # should also show rank 258
gst-launch-1.0 filesrc location=sample.h265 ! h265parse ! vkh265bridge ! fakesink
```

In the browser:

```sh
python3 range_server.py 8889 .        # a 206-capable server; the stdlib one is not
epiphany http://localhost:8889/test/test.html
```

A small generated H.264 test card ships at `test/sample.mp4`, and the page loads it by default, so you have something to play without hunting for a clip. Drop in your own file to test other streams. Watch `fuser /dev/video0` while it plays: it should stay busy. A note on the server: the stdlib `python3 -m http.server` answers byte-range requests with `200 OK` instead of `206 Partial Content`, and WebKit treats that as a network error and stalls. `range_server.py` answers ranges correctly.

## Reproduce the V4L2 zero-copy path (all four codecs)

This is the second path from the top of the README: no Vulkan, no ICD, zero-copy for H.264, HEVC, VP9 and AV1. The full write-up and the honest caveats are in [v4l2-zerocopy.md](v4l2-zerocopy.md); these are the steps end to end.

You will need:

- An RK3588 board whose kernel exposes the V4L2 stateless decoders: rkvdec for H.264/HEVC/VP9, and the Hantro AV1 block for AV1 (AV1 is not in every kernel build).
- GStreamer with the `v4l2codecs` plugin, plus `gstreamer-video-1.0` to build the element.
- WebKitGTK; I used 2.52 (Epiphany).

First, give the kernel a bigger CMA pool, or sustained playback exhausts contiguous memory and locks the board up (zero-copy means the browser holds the hardware buffers). Add `cma=512M` to the kernel command line and reboot:

```sh
# e.g. append cma=512M to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub, then:
sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo reboot
# after boot, confirm:
grep CmaTotal /proc/meminfo          # should read ~524288 kB
```

Build the element (it needs gstreamer-video-1.0 for GstVideoMeta):

```sh
make libgstv4l2metabridge.so
```

Point GStreamer at it. There is no ICD and no `VK_ICD_FILENAMES` here; this path does not use Vulkan:

```sh
export GST_PLUGIN_PATH=$PWD:$GST_PLUGIN_PATH
rm -f ~/.cache/gstreamer-1.0/registry.aarch64.bin
gst-inspect-1.0 | grep metabridge    # v4l2{h264,h265,vp8,vp9,mpeg2,av1}metabridge, all rank 258
```

In the browser, same local server, no special flags:

```sh
python3 range_server.py 8889 .
epiphany http://localhost:8889/test/test.html
```

While a video plays, watch which decode device is busy:

```sh
# rkvdec H.264/HEVC/VP9 -> /dev/video0 (or video1); Hantro AV1 -> /dev/video4
for n in 0 1 4; do fuser /dev/video$n 2>/dev/null && echo "  ^ video$n busy"; done
```

A device staying busy with a clean picture is hardware zero-copy. On real youtube.com the same setup decodes AV1 and VP9 at 360p, 720p and 1080p; mind the rough edges (bottom band, 480p/240p black, MSE-teardown crash) documented in [v4l2-zerocopy.md](v4l2-zerocopy.md).

## Please test it

I have run this on exactly one board. If you have an RK3588, or any SoC with a V4L2 stateless decoder and the Vulkan Video ICD, I would like to know whether it works for you. Open an issue with your board, your kernel, Mesa and GStreamer versions, and what happened. A report that it failed is as useful as a report that it worked.

## Where this goes next

H.264 and HEVC work now. VP9 and AV1 are the next codecs, and they are harder: both are frame-based rather than slice-based, so the driver work is more than mirroring what HEVC needed. The long-term-reference gap in the HEVC path is the other thing I want to close, once I have a stream that actually uses them.

The bigger item is dropping the system-memory copy. The decoded frame currently goes rkvdec to system RAM and back up to the GPU for display. A Mesa change that landed in June 2026 lets Panfrost's Vulkan driver sample an NV12 buffer with hardware YUV conversion, which is the piece that was missing for a zero-copy path on this hardware. I have not built on it yet, but it is the obvious direction, and it would want a newer system Mesa than the 26.0.6 I pinned for this. Turning the bridges into cleaner, upstreamable elements is the other open task.

## License

LGPL-2.1-or-later.
