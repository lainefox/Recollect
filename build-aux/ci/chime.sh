#!/bin/sh
# Play a short "the flatpak is built" chime.
#
# CI runners usually have no sound card, so this is strictly best effort: it
# renders a little melody to a WAV file with python, hands it to whichever
# audio player is installed, and falls back to terminal bells (plus the notes
# in the log) when nothing can play. It never fails the build.
#
# The melody is a rising arpeggio that lands on a held C: G5 C6 E6 G6 C6.
# Each entry is "name:frequency:seconds".
#
# Usage: chime.sh
set -u

melody='G5:783.99:0.10 C6:1046.50:0.10 E6:1318.51:0.10 G6:1567.98:0.14 C6:1046.50:0.42'

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT INT TERM
wav="$tmpdir/chime.wav"

render_melody() {
	# Only the frequency and the duration matter to the renderer.
	frequencies=''
	for entry in $melody; do
		frequencies="$frequencies ${entry#*:}"
	done
	command -v python3 >/dev/null 2>&1 || return 1
	python3 - "$wav" $frequencies <<'PYTHON' || return 1
import math
import struct
import sys
import wave

RATE = 44100
path, melody = sys.argv[1], [a.split(':') for a in sys.argv[2:]]

frames = bytearray()
for frequency, duration in ((float(f), float(d)) for f, d in melody):
    for i in range(int(RATE * duration)):
        t = i / RATE
        # Plucked string: quick attack, gentle decay, a little second harmonic.
        env = min(1.0, t / 0.006) * math.exp(-2.6 * t / duration)
        sample = math.sin(2 * math.pi * frequency * t)
        sample += 0.22 * math.sin(4 * math.pi * frequency * t)
        frames += struct.pack('<h', int(max(-1.0, min(1.0, sample * env * 0.45)) * 32767))

with wave.open(path, 'wb') as out:
    out.setnchannels(1)
    out.setsampwidth(2)
    out.setframerate(RATE)
    out.writeframes(bytes(frames))
PYTHON
}

# Keep this named something no audio player is called, so that "command -v"
# cannot find this function instead of the player we are looking for.
play_melody() {
	for player in \
		'paplay' \
		'pw-play' \
		'aplay -q' \
		'ffplay -nodisp -autoexit -loglevel quiet' \
		'play -q' \
		'afplay'; do
		command -v "${player%% *}" >/dev/null 2>&1 || continue
		if $player "$wav" 2>/dev/null; then
			printf 'chime played with %s: %s\n' "${player%% *}" "$melody"
			return 0
		fi
	done
	return 1
}

ring_bells() {
	printf 'chime (no audio device, ringing the terminal instead): %s\n' "$melody"
	for entry in $melody; do
		printf '\a'
		sleep "${entry##*:}"
	done
}

if render_melody && play_melody; then
	:
else
	ring_bells
fi

exit 0
