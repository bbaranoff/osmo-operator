#!/usr/bin/env bash
# tools/fft2.sh - FFT of the 2nd cfile. Reuses tools/fft.sh with another CFILE.
#
# tools/fft.sh  = dsp_iq.cfile = MS  (Calypso DSP input: the mobile answering the BTS)
# tools/fft2.sh = record.cfile = BTS (what the BTS transmits)
# -> SAME signal at both ends of the chain (BTS TX <-> MS RX); the difference
#    between the two spectra = what the chain (shunt/gr-gsm) does to the signal.
#
# Usage: ./tools/fft2.sh            (default CFILE=/dev/shm/record.cfile)
#        CFILE=... ./tools/fft2.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CFILE="${CFILE:-/dev/shm/record.cfile}"
export ARFCN="${ARFCN:-BTS-record}"
exec bash "$HERE/fft.sh" "$@"
