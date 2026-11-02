#!/bin/zsh
# Regenerates docs/media: the animation at the top of the README and the widget stills.
# Real views with staged sample data, drawn offscreen. It touches no volume and shows nothing on screen.
# The animation is filmed as it plays, so its bytes differ a little from run to run, and Reduce Motion on this Mac would show in it.
set -e -o pipefail
cd "${0:A:h}/.."
WORK=$(mktemp -d -t ingest-media)
trap 'rm -rf "$WORK"' EXIT
within() { perl -e 'alarm shift; exec { $ARGV[0] } @ARGV or die "$ARGV[0]: $!\n"' "$@"; }

within 900 swift build -j 4 --product IngestApp
within 300 swiftc -O scripts/apng.swift -o "$WORK/apng"
within 120 .build/debug/IngestApp --render "$WORK" --media

mkdir -p docs/media
cp "$WORK"/widget-*.png docs/media/
within 120 "$WORK/apng" "$WORK/frames" docs/media/demo.png
du -h docs/media/*
