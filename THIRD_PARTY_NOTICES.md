# Third-party notices

This repository contains **no third-party assets**. Everything committed here
(configs, Swift/GLSL/Python/shell source, themes, the synthesized alert sound
in `payload/sounds/`, screenshots) is original work covered by the repository
LICENSE (MIT).

At **install time**, `install.sh` downloads the following from their official
release channels. Each remains under its own license, listed here for
attribution; none of their code or files are redistributed by this repo:

| Project | License | Fetched from |
|---|---|---|
| [Cica font](https://github.com/miiton/Cica) | SIL Open Font License 1.1 | official GitHub releases |
| [bat](https://github.com/sharkdp/bat) | MIT / Apache-2.0 | Homebrew or official GitHub releases |
| [cmatrix](https://github.com/abishekvashok/cmatrix) | GPL-3.0 | Homebrew only |
| [SketchyBar](https://github.com/FelixKratz/SketchyBar) | Apache-2.0 | Homebrew or official GitHub releases |

Other notes:

- The default alert sound is synthesized from scratch by
  `tools/generate-ring.py` (in this repo). It is not a recording, sample, or
  recreation of any film audio or commercial ringtone. If you supply your own
  `matrix-ring.*` file, its rights are your responsibility.
- Short quotations from *The Matrix* appear as UI flavor text (greetings,
  spinner verbs). *The Matrix* and related marks are property of Warner Bros.
  Entertainment Inc.; this unaffiliated fan project uses brief quotes
  nominatively and ships no audio, video, or imagery from the films.
