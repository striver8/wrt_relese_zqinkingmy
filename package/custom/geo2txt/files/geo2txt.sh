#!/bin/sh
# geo2txt - minimal placeholder script for OpenWrt package
# (Replace with the real implementation if you have it)

if [ "$1" = "--version" ]; then
  echo "geo2txt 1.0"
  exit 0
fi

if [ -z "$1" ]; then
  echo "Usage: geo2txt <ip|data>"
  exit 0
fi

# minimal placeholder behaviour: echo argument
echo "$@"
exit 0
