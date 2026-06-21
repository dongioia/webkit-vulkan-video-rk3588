# WebKit hardware video decode through Vulkan Video on the RK3588

I got the GNOME Web browser (WebKitGTK / Epiphany) to hardware-decode H.264 on a Rockchip RK3588 board by routing it through a standalone Vulkan Video driver, with no patch to WebKit itself. This repository holds the small GStreamer bridge element that makes it work, plus what you need to reproduce it.

## Why I did this

Hardware video decode in a browser on the RK3588 has been a dead end for a while. The V4L2 path that mpv and GStreamer use is rejected upstream by Chromium, so it only survives in a downstream fork. Firefox has no working mainline-V4L2 path at all. There is no VA-API driver for the chip. Vulkan Video, meanwhile, is where the industry is heading. I wanted to find out whether a Vulkan Video driver could feed a real browser today, on this hardware.

It can.

## What works, and what doesn't

This is a proof of concept, so I want to be precise about what I actually verified:

- The decode is real hardware, and it is correct. The Vulkan Video driver runs H.264 on the RK3588's rkvdec block, and the first decoded frame matched an ffmpeg reference byte-for-byte.
- It actually plays in a browser. Epiphany decodes and shows an H.264 clip through this path with rkvdec busy the whole time and no software fallback. The video keeps playing, not just a frozen first frame.
- Nothing in WebKit was patched. The only moving parts are an out-of-tree GStreamer plugin and two environment variables.

The honest caveats:

- H.264 only. VP9, HEVC and AV1 are not done.
- I tested on one board: a Radxa Rock 5B+, kernel 7.1, Mesa 26.0.6, sway. I do not know how it behaves elsewhere, which is part of why I am publishing this.
- The decode-to-display path copies through system memory. There is no zero-copy yet.
- The byte-exact check is on the standalone decode. In-browser correctness is confirmed visually (a test pattern renders correctly), not byte-checked through the browser compositor.
- The bridge element is a proof of concept, not production code.

## How it works

The Vulkan Video decoder, `vulkanh264dec`, hands frames out as `memory:VulkanImage`. WebKit's GStreamer auto-plugger, `decodebin`, treats that opaque memory type as a dead end and will not insert a converter, so it falls back to software. The `vulkandownload` element can turn VulkanImage into plain system memory, but decodebin will not chain it in on its own.

So I wrote a tiny GStreamer bin, `vkh264bridge`, that wraps `vulkanh264dec ! vulkandownload` and presents itself to decodebin as an ordinary H.264 decoder with a plain `video/x-raw` NV12 output. decodebin then picks it like any other decoder, and the Vulkan context is shared internally between the two wrapped elements. That is the whole trick.

## The prerequisite: the Vulkan Video V4L2 driver

This sits on top of the experimental V4L2-backed Vulkan Video ICD from Sreerenj Balachandran's RFC ([Mesa issue #14987](https://gitlab.freedesktop.org/mesa/mesa/-/issues/14987), commit `5955e6e`), plus a small init-sequence fix I found and reported back there ([note 3528237](https://gitlab.freedesktop.org/mesa/mesa/-/work_items/14987#note_3528237)). Without that fix the decode comes out blank on rkvdec. You need that ICD built and working first: it should enumerate as "V4L2 Vulkan Video Decoder" in `vulkaninfo`.

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
export VK_ICD_FILENAMES=/path/to/v4l2vk_icd.aarch64.json
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
