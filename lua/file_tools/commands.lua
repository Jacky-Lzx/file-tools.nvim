local M = {}

function M.setup()
  for _, action in ipairs({ "Read", "Write" }) do
    require("file_tools.user_command").create("FileTools" .. action, function(args)
      local ok, err = pcall(
        require("file_tools")["privileged_" .. action:lower()],
        args.args ~= "" and args.args or nil,
        { force = args.bang }
      )
      if not ok then
        vim.notify("file-tools: " .. tostring(err), vim.log.levels.ERROR)
      end
    end, { nargs = "?", bang = true, complete = "file", desc = "Read or write a file using sudo" })
  end
  require("file_tools.user_command").create("FileTools", function(args)
    local sub, argument = args.args:match("^(%S+)%s*(.-)$")
    sub = sub or "toggle"
    argument = argument ~= "" and argument or nil
    local files = require("file_tools")
    local ok, err = pcall(function()
      if sub == "toggle" then
        files.toggle({ root = argument })
      elseif sub == "open" then
        files.open({ root = argument })
      elseif sub == "close" then
        files.close()
      elseif sub == "find" then
        files.find({ root = argument })
      elseif sub == "refresh" then
        require("file_tools.tree").refresh()
      elseif sub == "create" then
        assert(argument, "expected a path")
        local event, failure = files.create(argument, { directory = argument:sub(-1) == "/" })
        assert(event, failure)
      elseif sub == "rename" then
        assert(argument, "expected a destination path")
        local event, failure = files.rename(vim.api.nvim_buf_get_name(0), argument)
        assert(event, failure)
      else
        error("unknown FileTools action: " .. sub)
      end
    end)
    if not ok then
      vim.notify("file-tools: " .. tostring(err), vim.log.levels.ERROR)
    end
  end, {
    nargs = "*",
    desc = "File tree and operations",
    complete = function(lead, line)
      if line:match("^%s*FileTools%s+[^%s]*$") then
        return vim.tbl_filter(function(item)
          return item:sub(1, #lead) == lead
        end, {
          "toggle",
          "open",
          "close",
          "find",
          "refresh",
          "create",
          "rename",
        })
      end
      return vim.fn.getcompletion(lead, "file")
    end,
  })
end

return M
