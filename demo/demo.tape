# Records the README demo GIF with https://github.com/charmbracelet/vhs
#   vhs demo/demo.tape
# Needs a host named "demo" in ~/.ssh/config with a small project in ~/demo,
# and a Neovim config with telescope.nvim and this plugin loaded.
Output demo/demo.gif
Set FontSize 16
Set Width 1200
Set Height 700
Set TypingSpeed 60ms

Type "nvim" Enter
Sleep 1s
Type ":RemoteSSH open demo ~/demo" Enter
Sleep 8s
Type ":RemoteSSH files" Enter
Sleep 1s
Type "main"
Sleep 1s
Enter
Sleep 2s
Type ":RemoteSSH grep" Enter
Sleep 1s
Type "TODO"
Sleep 2s
Escape
Sleep 1s
Type ":RemoteSSH tree" Enter
Sleep 3s
