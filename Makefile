# vkh264bridge / vkh265bridge / v4l2metabridge — GStreamer plugins (build on the SBC)
# SPDX-License-Identifier: LGPL-2.1-or-later

PKGS  := gstreamer-1.0 gstreamer-base-1.0
CFLAGS := -shared -fPIC -O2 -Wall $(shell pkg-config --cflags $(PKGS))
LIBS   := $(shell pkg-config --libs $(PKGS))

# The v4l2 meta-bridge needs gstreamer-video-1.0 (GstVideoMeta).
VPKGS  := gstreamer-1.0 gstreamer-video-1.0
VCFLAGS := -shared -fPIC -O2 -Wall $(shell pkg-config --cflags $(VPKGS))
VLIBS   := $(shell pkg-config --libs $(VPKGS))

all: libgstvkh264bridge.so libgstvkh265bridge.so libgstv4l2metabridge.so

libgstvkh264bridge.so: gstvkh264bridge.c
	$(CC) $(CFLAGS) -o $@ $< $(LIBS) -Wl,-soname,libgstvkh264bridge.so

libgstvkh265bridge.so: gstvkh265bridge.c
	$(CC) $(CFLAGS) -o $@ $< $(LIBS) -Wl,-soname,libgstvkh265bridge.so

libgstv4l2metabridge.so: gstv4l2metabridge.c
	$(CC) $(VCFLAGS) -o $@ $< $(VLIBS) -Wl,-soname,libgstv4l2metabridge.so

clean:
	rm -f libgstvkh264bridge.so libgstvkh265bridge.so libgstv4l2metabridge.so

.PHONY: all clean
