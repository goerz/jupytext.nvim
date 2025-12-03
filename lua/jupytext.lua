local M = {}

-- Get the filetype that should be set for the buffer after loading ipynb file
function M.get_filetype(ipynb_file, format, metadata)
  if format == 'markdown' then
    return format
  elseif format == 'quarto' then
    return format
  elseif format == 'ipynb' then
    return 'json'
  elseif format:sub(1, 2) == 'md' then
    return 'markdown'
  elseif format:sub(1, 3) == 'Rmd' then
    return 'markdown'
  elseif format:sub(1, 2) == 'qmd' then
    return 'quarto'
  else
    if metadata and metadata.kernelspec then
      return metadata.kernelspec.language
    else
      return ''
    end
  end
end

-- Absolute path the the default .ipynb file to use as a template "new" files
function M.default_new_template()
  local script_path = debug.getinfo(1, 'S').source:sub(2)
  local script_dir = vim.fn.fnamemodify(script_path, ':h')
  local data_dir = vim.uv.fs_realpath(script_dir .. '/../data')
  return vim.uv.fs_realpath(data_dir .. '/template.ipynb')
end

-- Plugin options
M.opts = {
  jupytext = 'jupytext',
  format = 'markdown',
  update = true,
  filetype = M.get_filetype,
  new_template = M.default_new_template(),
  sync_patterns = { '*.md', '*.py', '*.jl', '*.R', '*.Rmd', '*.qmd' },
  autosync = true,
  handle_url_schemes = true,
  async_write = true, -- undocumented (for testing)
}

M.setup = function(opts)
  for key, value in pairs(opts) do
    if not M.opts[key] then
      vim.notify('Invalid option for jupytext.nvim: ' .. key, vim.log.levels.ERROR)
    end
    M.opts[key] = value
  end

  local augroup = vim.api.nvim_create_augroup('JupytextPlugin', { clear = true })

  -- read/write local .ipynb files
  vim.api.nvim_create_autocmd('BufReadCmd', {

    pattern = '*.ipynb',
    desc = 'Convert .ipynb file through jupytext on reading',
    group = augroup,

    callback = function(args)
      local ipynb_file = args.file -- may be relative path
      if ipynb_file:find('^.+://') then
        -- Bail out for URL-type files (like 'fugitive://', 'oil-ssh://')
        -- This is handled by the `BufReadPost` autocmd instead
        vim.cmd('edit ' .. vim.fn.fnameescape(ipynb_file))
        return
      end
      vim.cmd.doautocmd({ args = { 'BufReadPre', ipynb_file }, mods = { emsg_silent = true } })
      local bufnr = args.buf
      local metadata = M.open_notebook(ipynb_file, bufnr)
      local stat = vim.uv.fs_stat(ipynb_file)
      if stat then
        vim.b.mtime = stat.mtime
      else
        -- we're not dealing with an actual local file
        vim.b.jupytext_autosync = false
      end
      -- Local autocommands to handle two-way sync
      local buf_augroup = 'JupytextPlugin' .. bufnr
      vim.api.nvim_create_augroup(buf_augroup, { clear = true })

      vim.api.nvim_create_autocmd('BufWriteCmd', {
        buffer = bufnr,
        desc = 'Convert to native .ipynb json format through jupytext on writing',
        group = buf_augroup,
        callback = function(bufargs)
          vim.cmd.doautocmd({
            args = { 'BufWritePre', bufargs.file },
            mods = { emsg_silent = true },
          })
          local format = M.get_option('format')
          if (format ~= 'ipynb') and (bufargs.file:sub(-6) == '.ipynb') then
            M.write_notebook(bufargs.file, metadata, bufnr)
          else -- write without conversion
            local success = M.write_buffer(bufargs.file, bufnr)
            if success and (vim.o.cpoptions:find('%+') ~= nil) then
              vim.api.nvim_set_option_value('modified', false, { buf = bufnr })
            end
          end
          vim.cmd.doautocmd({
            args = { 'BufWritePost', bufargs.file },
            mods = { emsg_silent = true },
          })
        end,
      })

      if stat and M.get_option('autosync') and M.is_paired(metadata) then
        vim.api.nvim_set_option_value('autoread', true, { buf = bufnr })
        -- We need autoread to be true, because every save will trigger an
        -- update event from the `.ipynb` file being rewritten in the
        -- background.
        vim.api.nvim_create_autocmd('CursorHold', {
          buffer = bufnr,
          desc = 'Periodically check if Jupytext has updated paired files in the background',
          group = buf_augroup,
          callback = function()
            vim.api.nvim_command('checktime')
          end,
        })
      end

      vim.cmd.doautocmd({ args = { 'BufReadPost', ipynb_file }, mods = { emsg_silent = true } })
      vim.api.nvim_exec_autocmds('FileType', { buffer = bufnr })
    end,
  })

  -- autocommands for plain text files
  if M.get_option('autosync') and (#M.opts.sync_patterns > 0) then
    vim.api.nvim_create_autocmd('CursorHold', {
      pattern = M.opts.sync_patterns,
      desc = 'Periodically check if Jupytext has updated paired files in the background',
      group = augroup,
      callback = function()
        vim.api.nvim_command('checktime')
      end,
    })

    vim.api.nvim_create_autocmd('BufReadPre', {

      pattern = M.opts.sync_patterns,
      desc = 'Make sure paired Jupytext files are synced before reading',
      group = augroup,

      callback = function(args)
        local ipynb_file = args.file:match('^(.+)%.%w+$') .. '.ipynb'
        if M._file_exists(ipynb_file) then
          M.sync(ipynb_file)
          print('Synced with "' .. ipynb_file .. '" via jupytext')
        end
      end,
    })

    vim.api.nvim_create_autocmd('BufWritePost', {

      pattern = M.opts.sync_patterns,
      desc = 'Make sure paired Jupytext files are synced after writing',
      group = augroup,

      callback = function(args)
        local ipynb_file = args.file:match('^(.+)%.%w+$') .. '.ipynb'
        if M._file_exists(ipynb_file) then
          M.sync(ipynb_file, true) -- asynchronous
        end
      end,
    })
  end

  if M.get_option('handle_url_schemes') then
    -- autocommands for URL ipynb files (e.g., 'fugitive://.../*.ipynb')
    -- These assume that some other plugin handles BufReadCmd and BufWriteCmd,
    -- and we do the jupytext conversion purely within the buffer with
    -- `BufReadPost`, `BufWritePre`, and `BufWritePost`.
    vim.api.nvim_create_autocmd('BufReadPost', {

      pattern = '*://**/*.ipynb',
      group = augroup,

      callback = function(args)
        local bufnr = args.buf
        local url = args.file
        local json_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local metadata = M.get_metadata(json_lines)
        local tempdir = vim.fn.tempname()
        vim.fn.mkdir(tempdir)
        local basename = url:match('([^/]+)%.%w+$')
        local temp_ipynb_file = tempdir .. '/' .. basename .. '.ipynb'
        local format = M.get_option('format')
        if type(format) == 'function' then
          format = format(url, metadata)
        end
        local paired_formats = M.is_paired(metadata)

        if (format ~= 'ipynb') and M.write_buffer(temp_ipynb_file, bufnr) then
          local modified = vim.api.nvim_get_option_value('modified', { buf = bufnr })
          local jupytext = M.get_option('jupytext')
          local cmd =
            { jupytext, '--from', 'ipynb', '--to', format, '--output', '-', temp_ipynb_file }
          local proc = vim.system(cmd, { text = true }):wait()
          if proc.code == 0 then
            local text = proc.stdout:gsub('\n$', '') -- strip trailing newline
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(text, '\n'))
          else
            vim.notify(proc.stderr, vim.log.levels.ERROR)
          end
          local filetype = M.get_option('filetype')
          if type(filetype) == 'function' then
            filetype = filetype(url, format, metadata)
          end
          vim.api.nvim_set_option_value('filetype', filetype, { buf = bufnr })
          vim.api.nvim_set_option_value('modified', modified, { buf = bufnr })
          print('"' .. url .. '" via jupytext with format: ' .. format)
        end
        vim.b.jupytext_autosync = false
        vim.b.jupytext_async_write = false

        local buf_augroup = 'JupytextPlugin' .. bufnr
        vim.api.nvim_create_augroup(buf_augroup, { clear = true })

        -- convert the buffer back to json before writing
        vim.api.nvim_create_autocmd('BufWritePre', {
          group = buf_augroup,
          buffer = bufnr,
          callback = function()
            local modified = vim.api.nvim_get_option_value('modified', { buf = bufnr })
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local yaml_lines = M.get_yaml_lines(lines)
            local yaml_data = M.parse_yaml(yaml_lines)
            local extension = yaml_data.jupyter.jupytext.text_representation.extension
            local tempfile = tempdir .. '/' .. basename .. '.buffer'
            M.write_buffer(tempfile, lines) -- to recover buffer in BufWritePost
            local temp_plain_file = tempdir .. '/' .. basename .. extension
            M.write_buffer(temp_plain_file, lines)
            local jupytext = M.get_option('jupytext')
            local cmd = {
              jupytext,
              '--to',
              'ipynb',
              '--output',
              temp_ipynb_file,
              '--update',
              temp_plain_file,
            }
            local proc = vim.system(cmd):wait()
            if proc.code == 0 then
              M.sync(temp_ipynb_file, false, paired_formats)
              json_lines = M.read_file(temp_ipynb_file, true)
              vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, json_lines)
              vim.api.nvim_set_option_value('modified', modified, { buf = bufnr })
              -- Resetting the '[ '] markers is necessary for Fugitive
              vim.api.nvim_buf_set_mark(bufnr, '[', 1, 0, {})
              vim.api.nvim_buf_set_mark(bufnr, ']', #json_lines, 0, {})
            else
              vim.notify(proc.stderr, vim.log.levels.ERROR)
            end
          end,
        })

        -- convert the buffer back to plain text after writing
        vim.api.nvim_create_autocmd('BufWritePost', {
          group = buf_augroup,
          buffer = bufnr,
          callback = function()
            local modified = vim.api.nvim_get_option_value('modified', { buf = bufnr })
            local tempfile = tempdir .. '/' .. basename .. '.buffer'
            local lines = M.read_file(tempfile, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
            vim.api.nvim_set_option_value('modified', modified, { buf = bufnr })
          end,
        })
      end,
    })
  end
end

function M.get_option(name)
  local var_name = 'jupytext_' .. name
  if vim.b[var_name] ~= nil then
    return vim.b[var_name]
  elseif vim.g[name] ~= nil then
    return vim.g[var_name]
  else
    local value = M.opts[name]
    if value == nil then
      vim.notify('Invalid option for jupytext.nvim: ' .. name, vim.log.levels.ERROR)
    end
    return value
  end
end

function M.schedule(async, f)
  if async then
    vim.schedule(f)
  else
    f()
  end
end

-- Load ipynb file into the buffer via jupytext conversion.
-- The `ipynb_file` can be an existing file or a new file, but it must be a valid local path
function M.open_notebook(ipynb_file, bufnr)
  local source_file = vim.uv.fs_realpath(ipynb_file) -- absolute path if exists, or `nil`
  bufnr = bufnr or 0 -- current buffer, by default
  print('Loading via jupytext…')
  local autosync = M.get_option('autosync')
  if source_file and autosync then
    M.sync(source_file)
  end
  local json_lines = {}
  if source_file == nil then
    json_lines = M.read_file(M.get_option('new_template'), true)
  else
    local success, _json_lines = pcall(function()
      return M.read_file(ipynb_file, true)
    end)
    if success then
      json_lines = _json_lines
    end
  end
  local metadata = M.get_metadata(json_lines)
  local format = M.get_option('format')
  local jupytext = M.get_option('jupytext')
  if type(format) == 'function' then
    format = format(source_file, metadata)
  end
  if format == 'ipynb' then
    vim.api.nvim_buf_set_lines(bufnr, -2, -1, false, json_lines)
  else
    local cmd = { jupytext, '--from', 'ipynb', '--to', format, '--output', '-' }
    local proc = vim.system(cmd, { text = true, stdin = json_lines }):wait()
    if proc.code == 0 then
      local text = proc.stdout:gsub('\n$', '') -- strip trailing newline
      vim.api.nvim_buf_set_lines(bufnr, -2, -1, false, vim.split(text, '\n'))
    else
      vim.notify(proc.stderr, vim.log.levels.ERROR)
    end
  end
  local filetype = M.get_option('filetype')
  if type(filetype) == 'function' then
    filetype = filetype(source_file, format, metadata)
  end
  vim.api.nvim_set_option_value('filetype', filetype, { buf = bufnr })
  vim.api.nvim_set_option_value('modified', false, { buf = bufnr })
  print('"' .. ipynb_file .. '" via jupytext with format: ' .. format)
  vim.cmd('redraw')
  return metadata
end

-- Call `jupytext --sync` or `jupytext --set-formats` for the given ipynb file
function M.sync(ipynb_file, asynchronous, formats)
  local jupytext = M.get_option('jupytext')
  local cmd
  if formats then
    cmd = { jupytext, '--set-formats', formats, ipynb_file }
  else
    cmd = { jupytext, '--sync', ipynb_file }
  end
  local function on_exit(proc)
    if proc.code ~= 0 then
      vim.schedule(function()
        vim.notify(proc.stderr, vim.log.levels.ERROR)
      end)
    end
  end
  if asynchronous then
    vim.system(cmd, { text = true }, on_exit)
  else
    local proc = vim.system(cmd, { text = true }):wait()
    on_exit(proc)
  end
end

-- Write buffer to .ipynb file via jupytext conversion
function M.write_notebook(ipynb_file, metadata, bufnr)
  bufnr = bufnr or 0 -- current buffer, by default
  local buf_file = vim.uv.fs_realpath(vim.api.nvim_buf_get_name(bufnr))
  local write_in_place = (vim.uv.fs_realpath(ipynb_file) == buf_file)
  local buf_mtime = vim.b.mtime
  local stat = vim.uv.fs_stat(ipynb_file)
  if write_in_place then
    if stat and buf_mtime and (stat.mtime.sec ~= buf_mtime.sec) then
      vim.notify('WARNING: The file has been changed since reading it!!!', vim.log.levels.WARN)
      vim.notify('Do you really want to write to it (y/n)? ', vim.log.levels.INFO)
      local input = vim.fn.getchar()
      local key = vim.fn.nr2char(input)
      if key ~= 'y' then
        vim.notify('Aborted', vim.log.levels.INFO)
        return
      end
    end
  end
  local target_is_new = not (stat and stat.type == 'file')
  local has_cpo_plus = vim.o.cpoptions:find('%+') ~= nil
  metadata = metadata or {}
  local update = M.get_option('update')
  local via_tempfile = update
  local autosync = M.get_option('autosync')
  local jupytext = M.get_option('jupytext')
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cmd = { jupytext, '--to', 'ipynb', '--output', ipynb_file }
  if update then
    table.insert(cmd, '--update')
  end
  local formats = M.is_paired(metadata)
  local cmd_opts = {}
  local tempdir = nil
  if via_tempfile then
    tempdir = vim.fn.tempname()
    vim.fn.mkdir(tempdir)
    local yaml_lines = M.get_yaml_lines(lines)
    local yaml_data = M.parse_yaml(yaml_lines)
    local extension = yaml_data.jupyter.jupytext.text_representation.extension
    local basename = ipynb_file:match('([^/]+)%.%w+$')
    local tempfile = tempdir .. '/' .. basename .. extension
    M.write_buffer(tempfile, bufnr)
    table.insert(cmd, tempfile)
  else
    cmd_opts.stdin = lines
  end
  local async_write = M.get_option('async_write')
  local on_convert = function(proc)
    if proc.code == 0 then
      local msg = '"' .. ipynb_file .. '"'
      if target_is_new then
        msg = msg .. ' [New]'
      end
      msg = msg .. ' ' .. #lines .. 'L via jupytext [w]'
      print(msg)
      if write_in_place or has_cpo_plus then
        M.schedule(async_write, function()
          vim.api.nvim_set_option_value('modified', false, { buf = bufnr })
          if write_in_place then
            vim.b.mtime = vim.uv.fs_stat(ipynb_file).mtime
          end
        end)
      end
      if autosync and write_in_place and formats then
        M.sync(ipynb_file, async_write, formats)
        -- without autosync, the written file will be unpaired
      end
    else
      M.schedule(async_write, function()
        vim.notify(proc.stderr, vim.log.levels.ERROR)
      end)
    end
    if tempdir then
      M.schedule(async_write, function()
        vim.fn.delete(tempdir, 'rf')
      end)
    end
  end
  if async_write then
    vim.system(cmd, cmd_opts, on_convert)
  else
    local proc = vim.system(cmd, cmd_opts):wait()
    on_convert(proc)
  end
end

-- Write buffer or given lines to file "as-is"
function M.write_buffer(file, bufnr_or_lines)
  local success = false
  local lines = {}
  if type(bufnr_or_lines) == 'table' then
    lines = bufnr_or_lines
  else
    local bufnr = bufnr_or_lines or 0 -- current buffer, by default
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
  local fh = io.open(file, 'w')
  if fh then
    for _, line in ipairs(lines) do
      fh:write(line, '\n')
    end
    fh:close()
    success = true
  else
    error('Failed to open file for writing')
  end
  return success
end

function M._file_exists(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.type == 'file'
end

-- Read the metadata from the given lines of json data. Return nil if there is
-- no metadata
function M.get_metadata(json_lines)
  local json_str = table.concat(json_lines, '\n')
  local json_data = {}
  if #json_str > 0 then
    json_data = vim.json.decode(json_str)
  end
  return json_data.metadata
end

-- Get the content of the file as a multiline string or an array of lines
function M.read_file(file, as_lines)
  if as_lines then
    local lines = {}
    for line in io.lines(file) do
      table.insert(lines, line)
    end
    return lines
  else
    local fh = io.open(file, 'r')
    if not fh then
      error('Could not open file: ' .. file)
    end
    local content = fh:read('*all')
    fh:close()
    return content
  end
end

-- Get the json in the file as a Lua table (for debugging)
function M.get_json(ipynb_file)
  local content = M.read_file(ipynb_file)
  return vim.json.decode(content)
end

-- Does metadata indicate that underlying notebook is paired?
-- In non-boolean context, get the paired formats spec
function M.is_paired(metadata)
  if metadata and metadata.jupytext then
    return metadata.jupytext.formats
  end
  return nil
end

function M.get_yaml_lines(lines)
  if type(lines) == 'number' then
    local bufnr = lines -- get_yaml_lines(0) does the current buffer
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
  local yaml_lines = {}
  local line_nr = 1
  local first_line = lines[line_nr]
  local delimiters = {
    ['# ---'] = { '# ', '' },
    ['---'] = { '', '' },
    ['// ---'] = { '// ', '' },
    [';; ---'] = { ';; ', '' },
    ['% ---'] = { '% ', '' },
    ['/ ---'] = { '/ ', '' },
    ['-- ---'] = { '-- ', '' },
    ['(* ---'] = { '(* ', ' *)' },
    ['/* ---'] = { '/* ', ' */' },
  }
  local prefix = nil
  local suffix = nil
  for yaml_start, delims in pairs(delimiters) do
    if first_line:sub(1, #yaml_start) == yaml_start then
      prefix = delims[1]
      suffix = delims[2]
      break
    end
  end
  if prefix == nil or suffix == nil then
    error('Invalid YAML block')
    return {}
  end
  while line_nr < #lines do
    line_nr = line_nr + 1
    local line = lines[line_nr]:sub(#prefix + 1)
    if suffix ~= '' then
      line = line:sub(1, -#suffix)
    end
    if line == '---' then
      break
    else
      table.insert(yaml_lines, line)
    end
  end
  return yaml_lines
end

-- limited YAML parser for the subset of YAML that will appear in the metadata
-- YAML header generated by jupytext
function M.parse_yaml(lines)
  local result_table = {}
  local stack = {}
  local indent_stack = {} -- Array of ints (spaces per indent level)
  local current_indent = ''

  for _, line in ipairs(lines) do
    local leading_spaces = line:match('^(%s*)')
    local trimmed_line = line:match('^%s*(.-)%s*$')

    if #leading_spaces < #current_indent then
      local delta = #current_indent - #leading_spaces
      while (delta > 0) and (#indent_stack > 0) do
        delta = delta - indent_stack[#indent_stack]
        table.remove(indent_stack)
        table.remove(stack)
      end
    elseif #leading_spaces > #current_indent then
      table.insert(indent_stack, #leading_spaces - #current_indent)
    end
    current_indent = leading_spaces
    if #trimmed_line > 0 then
      if trimmed_line:sub(-1) == ':' then
        local sub_table_name = trimmed_line:sub(1, -2)
        table.insert(stack, sub_table_name)
      else
        local key, value = trimmed_line:match('^(.+):%s*(.+)$')
        if value:sub(1, 1) == "'" and value:sub(-1) == "'" then
          value = value:sub(2, -2)
        end
        local current_subtable = result_table
        for _, k in ipairs(stack) do
          current_subtable[k] = current_subtable[k] or {}
          current_subtable = current_subtable[k]
        end
        current_subtable[key] = value
      end
    end
  end

  return result_table
end

function M.get_yamldata(bufnr)
  bufnr = bufnr or 0 -- current buffer, by default
  local lines = M.get_yaml_lines(bufnr)
  return M.parse_yaml(lines)
end

return M
