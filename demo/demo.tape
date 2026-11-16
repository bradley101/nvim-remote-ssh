# Records the README demo GIF with https://github.com/charmbracelet/vhs
#   vhs demo/demo.tape
# Needs a host "demo" in your ssh config (RSSH_DEMO_SSH_CONFIG to use another
# config file) with a checkout of Neovim's source in ~/neovim, reached
# through two jump hosts in the recording. Connect once beforehand so the
# one-time install prompt is not recorded.
Output demo/demo.gif
Set Shell zsh
Set FontSize 15
Set Width 1400
Set Height 800
Set Padding 16
Set TypingSpeed 45ms

Hide
Type ". demo/truecolor.sh && clear" Enter
Sleep 500ms
Type "nvim -u demo/init.lua" Enter
Sleep 1.5s
Show

Type ":RemoteSSH open demo ~/neovim"
Sleep 400ms
Enter
Sleep 5s

Type ":RemoteSSH files" Enter
Sleep 1s
Type "eval.c"
Sleep 1.2s
Enter
Sleep 2s

Type ":RemoteSSH grep" Enter
Sleep 1s
Type "nvim_buf_set_lines"
Sleep 2.5s
Down
Sleep 600ms
Down
Sleep 1s
Enter
Sleep 3s
