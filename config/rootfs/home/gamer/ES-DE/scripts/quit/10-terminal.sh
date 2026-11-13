#!/bin/sh
# ES-DE quit menu -> plain console on tty1.
# The switch stops this session, so rg35xx-session only queues the start job (--no-block).
exec sudo -n /usr/local/bin/rg35xx-session terminal
