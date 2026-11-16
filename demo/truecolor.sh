# Sourced by demo/demo.tape. Neovim writes truecolor as `38:2:R:G:B`, which
# the terminal vhs records reads with a colour-space field (shifting every
# colour). A terminfo entry with the `38;2;R;G;B` form avoids that.
export TERMINFO="$(mktemp -d)"
{
  infocmp -x xterm-256color
  printf '\tsetrgbf=\\E[38;2;%%p1%%d;%%p2%%d;%%p3%%dm,\n\tsetrgbb=\\E[48;2;%%p1%%d;%%p2%%d;%%p3%%dm,\n'
} | tic -x -o "$TERMINFO" - 2>/dev/null
export TERM=xterm-256color
