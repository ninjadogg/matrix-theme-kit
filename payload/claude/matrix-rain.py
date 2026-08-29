#!/usr/bin/env python3
"""Matrix digital rain. Ctrl-C to exit."""
import argparse, os, random, shutil, signal, sys, time

GLYPHS = [chr(c) for c in range(0xFF66, 0xFF9E)] + list("0123456789:.=*+-<>|╌╫")

HEAD   = "\033[97m"      # near-white leading glyph
BRIGHT = "\033[92m"      # bright green just behind the head
MID    = "\033[32m"      # body
DIM    = "\033[2;32m"    # fading tail
RESET  = "\033[0m"


class Column:
    def __init__(self, rows):
        self.rows = rows
        self.reset(initial=True)

    def reset(self, initial=False):
        # seed mid-fall on startup so the screen is full from frame one
        self.head = random.uniform(0, self.rows * 1.3) if initial else random.uniform(-20, -1)
        self.speed = random.uniform(0.25, 1.1)
        self.length = random.randint(max(4, self.rows // 5), max(6, self.rows))
        self.glyphs = [random.choice(GLYPHS) for _ in range(self.rows + 2)]
        self.idle = random.uniform(0, 1.5) if not initial else 0.0

    def advance(self):
        if self.idle > 0:
            self.idle -= 0.05
            return
        self.head += self.speed
        # occasionally mutate a visible glyph so the stream shimmers
        if random.random() < 0.35:
            i = random.randrange(len(self.glyphs))
            self.glyphs[i] = random.choice(GLYPHS)
        if self.head - self.length > self.rows:
            self.reset()

    def cell(self, row):
        d = self.head - row
        if d < 0 or d > self.length:
            return None
        g = self.glyphs[row % len(self.glyphs)]
        if d < 1:
            return HEAD + g
        if d < 3:
            return BRIGHT + g
        if d < self.length * 0.55:
            return MID + g
        return DIM + g


def run(fps, frames):
    cols, rows = shutil.get_terminal_size((100, 30))
    columns = [Column(rows) for _ in range(cols)]
    delay = 1.0 / fps
    n = 0
    while frames is None or n < frames:
        buf = ["\033[H"]
        for r in range(rows):
            line = []
            for c in columns:
                ch = c.cell(r)
                line.append(ch if ch else " ")
            buf.append("".join(line) + RESET)
            if r < rows - 1:
                buf.append("\n")
        sys.stdout.write("".join(buf))
        sys.stdout.flush()
        for c in columns:
            c.advance()
        n += 1
        time.sleep(delay)


def main():
    ap = argparse.ArgumentParser(description="Matrix digital rain")
    ap.add_argument("--fps", type=float, default=20.0)
    ap.add_argument("--frames", type=int, default=None,
                    help="render N frames then exit (default: run until Ctrl-C)")
    a = ap.parse_args()

    interactive = sys.stdout.isatty()
    try:
        if interactive:
            sys.stdout.write("\033[?1049h\033[?25l")   # alt screen, hide cursor
        run(a.fps, a.frames)
    except KeyboardInterrupt:
        pass
    finally:
        if interactive:
            sys.stdout.write("\033[?25h\033[?1049l")   # restore
        sys.stdout.write(RESET)
        sys.stdout.flush()


if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal.default_int_handler)
    main()
