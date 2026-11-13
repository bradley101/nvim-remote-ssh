#!/bin/sh
# Builds a fake "release server" tree: archives shaped like the real ones,
# whose binaries are wrappers around the tools installed on this machine.
set -eu
WWW=$1
ARCH=$(uname -m); case $ARCH in aarch64|arm64) NA=arm64; RT=aarch64-unknown-linux-gnu ;; *) NA=x86_64; RT=x86_64-unknown-linux-musl ;; esac
rm -rf "$WWW"; mkdir -p "$WWW/good" "$WWW/badsum" "$WWW/nosum" "$WWW/build"
B=$WWW/build

# Neovim
mkdir -p "$B/nvim-linux-$NA/bin"
printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v nvim)" > "$B/nvim-linux-$NA/bin/nvim"
chmod +x "$B/nvim-linux-$NA/bin/nvim"
tar -czf "$WWW/good/nvim-linux-$NA.tar.gz" -C "$B" "nvim-linux-$NA"
(cd "$WWW/good" && sha256sum "nvim-linux-$NA.tar.gz" > shasum.txt)
cp "$WWW/good/nvim-linux-$NA.tar.gz" "$WWW/badsum/"
echo "0000000000000000000000000000000000000000000000000000000000000000  nvim-linux-$NA.tar.gz" > "$WWW/badsum/shasum.txt"
cp "$WWW/good/nvim-linux-$NA.tar.gz" "$WWW/nosum/"

# ripgrep
RG=ripgrep-14.1.1-$RT
mkdir -p "$B/$RG"
printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v rg)" > "$B/$RG/rg"
chmod +x "$B/$RG/rg"
tar -czf "$WWW/good/$RG.tar.gz" -C "$B" "$RG"
(cd "$WWW/good" && sha256sum "$RG.tar.gz" > "$RG.tar.gz.sha256")

# mason.nvim stand-in implementing the parts of the API the agent uses.
M=$B/mason.nvim-2.0.1
mkdir -p "$M/lua/mason" "$M/lua/mason-registry"
cat > "$M/lua/mason/init.lua" <<'L'
local M = { opts = {} }
function M.setup(opts) M.opts = opts end
return M
L
cat > "$M/lua/mason-registry/init.lua" <<'L'
local R = {}
local root = function() return require("mason").opts.install_root_dir end
local specs = { { name = "fake-language-server", neovim = { lspconfig = "fakels" } }, { name = "broken-server", neovim = { lspconfig = "brokenls" } } }
function R.refresh(cb) vim.defer_fn(cb, 10) end
function R.get_all_package_specs() return specs end
function R.has_package(n) for _, s in ipairs(specs) do if s.name == n then return true end end return false end
function R.get_package(name)
  local pkg = { name = name }
  function pkg:is_installed() return vim.loop.fs_stat(root() .. "/bin/" .. name) ~= nil end
  function pkg:install(_, cb)
    local handle = { on = function(_, ev, fn) if ev == "stdout" then fn("installing " .. name .. "\n") end end }
    vim.defer_fn(function()
      if name == "broken-server" then return cb(false, "npm is not installed") end
      vim.fn.mkdir(root() .. "/bin", "p")
      local src = "@FAKE_LS@"
      vim.loop.fs_copyfile(src, root() .. "/bin/" .. name)
      vim.loop.fs_chmod(root() .. "/bin/" .. name, 493)
      cb(true)
    end, 50)
    return handle
  end
  return pkg
end
return R
L
sed -i "s|@FAKE_LS@|$(cd "$(dirname "$0")" && pwd)/fake_ls.py|" "$M/lua/mason-registry/init.lua"
tar -czf "$WWW/good/mason.tar.gz" -C "$B" mason.nvim-2.0.1
rm -rf "$B"
