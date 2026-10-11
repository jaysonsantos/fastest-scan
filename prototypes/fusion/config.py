"""Frame ranges and reference frames of the three studied spreads (checked against the CSV
and the overlay pictures)."""

SPREADS = {
    # "Charging your headphones", 17.1 s .. 20.9 s
    "A": dict(
        ref={0: 568, 1: 541},
        stable=list(range(502, 577, 3)),
        early=list(range(470, 502, 2)),
        all=(462, 578),
    ),
    # "Button functions", 28.5 s .. 32.8 s. Frames 900+ are zoomed in (bottom of page out of frame)
    "B": dict(
        ref={0: 840, 1: 840},
        stable=list(range(824, 922, 4)),
        early=list(range(796, 824, 2)),
        all=(795, 925),
    ),
    # "Technical specs" / "Safety precautions", 38.3 s .. 40.8 s. Frames 1136+ are clipped at the top
    "C": dict(
        ref={0: 1108, 1: 1109},
        stable=list(range(1090, 1161, 3)),
        early=list(range(1064, 1090, 2)),
        all=(1062, 1165),
    ),
}
