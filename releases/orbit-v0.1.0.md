# your desk as the windows of a station in low orbit

Behind your desktops, a planet turns beneath you: NASA's imagery of the Earth under a physically scattered atmosphere, in real time — clouds, sun glint on the oceans, city lights and the green airglow on the night side. Every monitor is a pane of the same window, so the view runs continuously across your desk.

Each desktop is a place on the station. Moving right along a row turns you a third of the way round; moving down a row carries you a third of the way along the orbit, from day to the terminator to night. Every switch is the same smooth move — 3 → 4 and 9 → 1 included — and nothing ever swings more than 120°.

In the overview, every cell is its desktop's viewport.

    hyprpeach plugin add orbit

Needs Rust and ImageMagick; the first add builds the renderer and fetches the planet. At rest it draws ten frames a second.
