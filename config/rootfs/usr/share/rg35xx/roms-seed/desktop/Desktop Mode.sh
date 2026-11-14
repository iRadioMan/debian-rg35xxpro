#!/bin/sh
# ES-DE "desktop" system entry -> labwc session on tty1. Stopping ES-DE is part of the switch.
exec sudo -n /usr/local/bin/rg35xx-session desktop
