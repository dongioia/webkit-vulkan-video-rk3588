# vkh264bridge / vkh265bridge — GStreamer plugins (build on the SBC)
# SPDX-License-Identifier: LGPL-2.1-or-later

PKGS  := gstreamer-1.0 gstreamer-base-1.0
CFLAGS := -shared -fPIC -O2 -Wall $(shell pkg-config --cflags $(PKGS))
LIBS   := $(shell pkg-config --libs $(PKGS))

all: libgstvkh264bridge.so libgstvkh265bridge.so

libgstvkh264bridge.so: gstvkh264bridge.c
	$(CC) $(CFLAGS) -o $@ $< $(LIBS) -Wl,-soname,libgstvkh264bridge.so

libgstvkh265bridge.so: gstvkh265bridge.c
	$(CC) $(CFLAGS) -o $@ $< $(LIBS) -Wl,-soname,libgstvkh265bridge.so

clean:
	rm -f libgstvkh264bridge.so libgstvkh265bridge.so

.PHONY: all clean
