# a living scene behind every desktop

Behind your desktops, one scene in real time — a neon synthwave grid running to a banded sun, or the inside of a nebula — with a different place in it for each of the nine desktops: its own colours, its own landmark. You know which desktop you are on without reading a number.

Switching flies you from one place to the next: a surge along the grid, a flight through the gas. Every switch is the same move forward, 9 → 1 included.

The picture runs across all your monitors as one, composed around the one at eye level: on two stacked panels the subject sits on the bottom one and the sky goes on up through the top; on a laptop between two larger screens the horizon runs on across both; a laptop on its own gets the whole of it.

    hyprpeach plugin add orbit
    hyprpeach scene nebula

Needs Rust; the first add builds the renderer. Every frame is drawn fresh — measured at 60 fps on two 7680 × 2160 panels.
