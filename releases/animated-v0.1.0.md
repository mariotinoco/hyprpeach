# animated-desktops, renamed, and no Rust to install

The same plugin as animated-desktops 0.1.0, under a shorter name. An install that had it is carried over by `hyprpeach upgrade`, settings and all.

It no longer needs Rust installed: the renderer builds with the Rust its `mise.toml` pins, which mise — part of every Omarchy install — fetches the first time.

    hyprpeach plugin add animated
