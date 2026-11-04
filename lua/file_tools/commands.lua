local M = {}

function M.setup()
  vim.api.nvim_create_user_command("FileTools", function(args)
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
      elseif sub == "yazi" then
        files.yazi({ path = argument })
      elseif sub == "yazi-cwd" then
        files.yazi({ cwd = true })
      elseif sub == "yazi-toggle" then
        require("file_tools.yazi").toggle({ resume = true })
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
    desc = "File tree, operations and Yazi",
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
          "yazi",
          "yazi-cwd",
          "yazi-toggle",
          "create",
          "rename",
        })
      end
      return vim.fn.getcompletion(lead, "file")
    end,
  })
end

return M
