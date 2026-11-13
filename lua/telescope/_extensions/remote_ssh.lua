-- :Telescope remote_ssh {hosts|recent|files|live_grep|symbols}
local function with_context(fn)
  return function(opts)
    opts = opts or {}
    local rs = require("remote-ssh")
    local host, root = rs.context()
    local conn = host and require("remote-ssh.connection").get(host)
    if not conn or conn.state ~= "connected" then
      return require("remote-ssh.log").warn("No remote workspace is open. Use :RemoteSSH open")
    end
    opts.conn, opts.root = conn, opts.root or root
    fn(opts)
  end
end

return require("telescope").register_extension({
  exports = {
    hosts = function(opts)
      require("remote-ssh.telescope").hosts(opts)
    end,
    recent = function(opts)
      require("remote-ssh.telescope").recent(opts)
    end,
    files = with_context(function(opts)
      require("remote-ssh.telescope").files(opts)
    end),
    live_grep = with_context(function(opts)
      require("remote-ssh.telescope").live_grep(opts)
    end),
    symbols = function(opts)
      require("remote-ssh.telescope").symbols(opts or {})
    end,
  },
})
