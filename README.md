# WebKit hardware video decode through Vulkan Video on the RK3588

I got the GNOME Web browser (WebKitGTK / Epiphany) to hardware-decode H.264 on a Rockchip RK3588 board by routing it through a standalone Vulkan Video driver, with no patch to WebKit itself. This repository holds the small GStreamer bridge element that makes it work, plus what you need to reproduce it.

## Why I did this

Hardware video decode in a browser on the RK3588 has been a dead end for a while. The V4L2 path that mpv and GStreamer use is rejected upstream by Chromium, so it only survives in a downstream fork. Firefox has no working mainline-V4L2 path at all. There is no VA-API driver for the chip. Vulkan Video, meanwhile, is the direction the desktop GPU stacks are taking, so it seemed like the thing to bet on. I wanted to find out whether a Vulkan Video driver could feed a real browser today, on this hardware.

It can.

## What works, and what doesn't

This is a proof of concept, so I want to be precise about what I actually verified:

- The decode is real hardware, and it is correct. The Vulkan Video driver runs H.264 on the RK3588's rkvdec block, and the decoded frames match an ffmpeg reference byte-for-byte at every resolution I tried, 360p through 1080p, cropped sizes included.
- It actually plays in a browser. Epiphany decodes and plays an H.264 clip this way, including a real one I pulled off YouTube, with rkvdec busy the whole time and no software fallback. The video keeps playing, not just a frozen first frame.
- Nothing in WebKit was patched. The only moving parts are an out-of-tree GStreamer plugin and two environment variables.

The honest caveats:

- H.264 only. VP9, HEVC and AV1 are not done.
- I tested on one board: a Radxa Rock 5B+, kernel 7.1, Mesa 26.0.6, sway. I do not know how it behaves elsewhere, which is part of why I am publishing this.
- The decode-to-display path copies through system memory. There is no zero-copy yet.
- The byte-exact check is on the standalone decode. In-browser correctness is confirmed visually (the picture is right), not byte-checked through the browser compositor.
- The bridge element is a proof of concept, not production code.

## How it works

The Vulkan Video decoder, `vulkanh264dec`, hands frames out as `memory:VulkanImage`. WebKit's GStreamer auto-plugger, `decodebin`, treats that opaque memory type as a dead end and will not insert a converter, so it falls back to software. The `vulkandownload` element can turn VulkanImage into plain system memory, but decodebin will not chain it in on its own.

So I wrote a tiny GStreamer bin, `vkh264bridge`, that wraps `vulkanh264dec ! vulkandownload` and presents itself to decodebin as an ordinary H.264 decoder with a plain `video/x-raw` NV12 output. decodebin then picks it like any other decoder, and the Vulkan context is shared internally between the two wrapped elements. That is the whole trick.

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

- An RK3588 board with a mainline kernel that exposes rkvdec (V4L2 stateless H.264).
- GStreamer 1.28 or newer, with the `vulkan` and `v4l2codecs` plugins.
- The Vulkan Video V4L2 ICD above, deployed and enumerating.

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

In the browser:

```sh
python3 range_server.py 8889 .        # a 206-capable server; the stdlib one is not
epiphany http://localhost:8889/test/test.html
```

A small generated H.264 test card ships at `test/sample.mp4`, and the page loads it by default, so you have something to play without hunting for a clip. Drop in your own file to test other streams. Watch `fuser /dev/video0` while it plays: it should stay busy. A note on the server: the stdlib `python3 -m http.server` answers byte-range requests with `200 OK` instead of `206 Partial Content`, and WebKit treats that as a network error and stalls. `range_server.py` answers ranges correctly.

## Please test it

I have run this on exactly one board. If you have an RK3588, or any SoC with a V4L2 stateless decoder and the Vulkan Video ICD, I would like to know whether it works for you. Open an issue with your board, your kernel, Mesa and GStreamer versions, and what happened. A report that it failed is as useful as a report that it worked.

## Where this goes next

H.264 is the start. The same bridge idea should extend to HEVC, VP9 and AV1 as the Vulkan Video drivers grow to cover them. Skipping the system-memory copy (zero-copy) and turning the bridge into a cleaner, upstreamable element are the obvious next steps.

## License

LGPL-2.1-or-later.
