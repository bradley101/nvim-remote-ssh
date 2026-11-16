# Records the README demo GIF with https://github.com/charmbracelet/vhs
#   vhs demo/demo.tape
# Needs a host "demo" in your ssh config (RSSH_DEMO_SSH_CONFIG to use another
# config file) with a checkout of Neovim's source in ~/neovim, reached
# through two jump hosts in the recording, and lua-language-server installed
# there (open a Lua file once and accept the install). Connect once
# beforehand so the one-time install prompt is not recorded.
Output demo/demo.gif
Output demo/demo.mp4
Set Shell zsh
Set FontSize 15
Set Width 1400
Set Height 800
Set Padding 16
Set Framerate 24
Set TypingSpeed 75ms

Hide
Type ". demo/truecolor.sh && export NVIM_APPNAME=rssh-demo && clear" Enter
Sleep 500ms
Type "nvim -u demo/init.lua" Enter
Sleep 1.5s
Show

# Connect through two jump hosts; the explorer opens.
Type ":RemoteSSH open demo ~/neovim"
Sleep 600ms
Enter
Sleep 6s

# Browse the server's files.
Type "/src/" Enter
Sleep 700ms
Type "l"
Sleep 1.2s
Type "/nvim/" Enter
Sleep 700ms
Type "l"
Sleep 2.5s

# Find a file among ~4000.
Type ":RemoteSSH files" Enter
Sleep 1.5s
Type "core/shared.lua"
Sleep 2s
Enter
Sleep 3s

# Jump to a symbol.
Type ":RemoteSSH symbols" Enter
Sleep 1.5s
Type "can_merge"
Sleep 2s
Enter
Sleep 2s

# The language server runs on the server: hover, then go to definition.
Type "j/tbl_isempty" Enter
Sleep 1.2s
Type "K"
Sleep 4s
Type "gd"
Sleep 3s

# Live grep across the repository.
Type ":RemoteSSH grep" Enter
Sleep 1.5s
Type "nvim_buf_set_lines"
Sleep 3s
Down
Sleep 900ms
Down
Sleep 1.5s
Enter
Sleep 3s

# A shell on the server, in the workspace folder.
Type ":RemoteSSH terminal" Enter
Sleep 2s
Type "hostname && git log --oneline -3" Enter
Sleep 3.5s
Type "exit" Enter
Sleep 1s
Escape
Sleep 500ms

# Quit, start Neovim again, and reopen the workspace from the recent list.
Type ":qa!" Enter
Sleep 800ms
Hide
Type "clear && nvim -u demo/init.lua" Enter
Sleep 1.5s
Show
Type ":RemoteSSH recent" Enter
Sleep 2.5s
Enter
Sleep 6s
