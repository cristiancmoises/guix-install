# GNU Guix logo attribution

Copyright © 2015 Luis Felipe López Acevedo (sirgazil).
Licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
Official source and license statement: [GNU Guix graphics](https://guix.gnu.org/en/graphics/).

`guix-logo.svg` is the unchanged flat head from the official `guix/artwork`
repository at the commit and URL recorded in `provenance.json`.
`guix-logo.png` is a scaled transparent rendering for Tk;
`guix-logo.txt` is an ASCII adaptation of its silhouette, sampled to 36×16 cells.
The derived files retain CC BY-SA 4.0; these conversions are modifications.
Use of the logo does not imply GNU Guix endorsement of this community installer.

To reproduce with librsvg and ImageMagick: render with
`rsvg-convert -w 160 -h 140 -a guix-logo.svg -o guix-logo.png`, then sample
its alpha channel with `scripts/render-terminal-logo.py`.
