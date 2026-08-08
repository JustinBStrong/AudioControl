# In-car delay measurement

Measured at the listening position using the MacBook microphone and the
Ultrbeka-BR02 Bluetooth receiver. The engine was off for all retained timing
captures.

## Method

The initial logarithmic sweeps established levels and broad impulse-response
timing. Sparse Ricker wavelets were then used in the electrical/acoustic overlap
region. A door-only reference was captured by temporarily applying -36 dB trim
to the ESP output. Production DSP was otherwise bypassed selectively for
measurement, then restored.

At 500 Hz with zero ESP delay, the combined capture showed the direct sub path
followed by the processed door path. Three separations were 241.3 ms, 229.6 ms,
and 241.0 ms. The 229.6 ms trial contained a recording discontinuity; the
median was 241.0 ms. Applying 241 ms collapsed the dual arrivals to one in all
three verification pulses.

An initial coefficient-only correction produced 235.4 ms, but a subsequent
paired-wavelet measurement tested the complete production path directly. Each
source pulse contained simultaneous 80 Hz and 500 Hz components: the 80 Hz
component tracked the filtered sub path and the 500 Hz component tracked the
door path in the same recording, eliminating Bluetooth start-time jitter.

At 235.4 ms the sub envelope was 18-20 ms late. Iterative production-path
measurements converged on 212.7 ms. The final unchanged repeat measured 1.315,
0.295, and 0.771 ms late, with a 0.771 ms median. This is below the practical
resolution imposed by the cabin reflections, broad 80 Hz envelope, and built-in
MacBook microphone.

## Saved production configuration

- Delay: 212.7 ms, enabled
- Low-pass: 80 Hz, enabled
- Bass shelf: disabled
- Output trim: 0.00 dB
- DSP bypass: disabled
- Verified applied configuration revision: 277
