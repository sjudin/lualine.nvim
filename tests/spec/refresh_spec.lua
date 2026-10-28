local eq = assert.are.same
local lualine = require('lualine')

describe('Refresh scheduling', function()
  local draws, value, on_draw, config

  local function wait(ms)
    vim.wait(ms, function()
      return false
    end, 1)
  end

  local function request()
    lualine.refresh { place = { 'statusline' } }
  end

  before_each(function()
    draws, value, on_draw = 0, 'initial', nil
    config = {
      options = {
        theme = 'gruvbox',
        icons_enabled = false,
        refresh = {
          statusline = 60000,
          tabline = 60000,
          winbar = 60000,
          refresh_time = 80,
          events = { 'ModeChanged' },
        },
      },
      sections = {
        lualine_a = {
          function()
            draws = draws + 1
            if on_draw then
              local callback = on_draw
              on_draw = nil
              callback()
            end
            return value
          end,
        },
        lualine_b = {},
        lualine_c = {},
        lualine_x = {},
        lualine_y = {},
        lualine_z = {},
      },
      inactive_sections = {},
      tabline = {},
      winbar = {},
    }
    lualine.setup(config)
    wait(180)
    draws = 0
  end)

  after_each(function()
    on_draw = nil
    lualine.hide()
    wait(100)
  end)

  it('does not leave a repeating refresh checker running while idle', function()
    local schedule = vim.schedule
    local callbacks = 0
    vim.schedule = function(callback)
      callbacks = callbacks + 1
      return schedule(callback)
    end
    local ok, err = pcall(wait, 100)
    vim.schedule = schedule
    assert(ok, err)
    eq(0, callbacks)
    eq(0, draws)
  end)

  it('processes the first event after idle on the next event-loop turn', function()
    config.options.refresh.refresh_time = 1000
    lualine.setup(config)
    -- Let both the setup request and the initial periodic-timer request drain.
    wait(2200)
    draws = 0
    value = 'changed mode'
    vim.api.nvim_exec_autocmds('ModeChanged', { pattern = 'n:i' })
    eq(0, draws)
    assert(vim.wait(100, function()
      return draws > 0
    end, 1))
    assert(vim.o.statusline:find('changed mode', 1, true))
  end)

  it('coalesces a burst of requests into one refresh', function()
    for _ = 1, 100 do
      request()
    end
    eq(0, draws)
    wait(100)
    eq(1, draws)
  end)

  it('coalesces requests independently for each segment', function()
    local tabline_draws = 0
    config.tabline = {
      lualine_a = {
        function()
          tabline_draws = tabline_draws + 1
          return 'tabline'
        end,
      },
    }
    lualine.setup(config)
    wait(180)
    draws, tabline_draws = 0, 0
    lualine.refresh { place = { 'statusline', 'tabline' } }
    request()
    wait(100)
    eq(1, draws)
    eq(1, tabline_draws)
  end)

  it('limits repeated events without postponing the pending batch', function()
    request()
    assert(vim.wait(30, function()
      return draws == 1
    end, 1))
    for _ = 1, 5 do
      request()
      wait(5)
    end
    eq(1, draws)
    assert(vim.wait(100, function()
      return draws == 2
    end, 1))
    wait(100)
    eq(2, draws)
  end)

  it('keeps requests made by a component for the following batch', function()
    on_draw = function()
      value = 'requested during refresh'
      request()
    end
    request()
    assert(vim.wait(200, function()
      return draws == 2
    end, 1))
    assert(vim.o.statusline:find(value, 1, true))
  end)

  it('retains synchronous forced refreshes', function()
    request()
    assert(vim.wait(30, function()
      return draws == 1
    end, 1))
    value = 'forced'
    lualine.refresh { place = { 'statusline' }, force = true }
    eq(2, draws)
    assert(vim.o.statusline:find(value, 1, true))
  end)

  it('discards scheduled work belonging to an earlier setup', function()
    request()
    config.sections.lualine_a = {
      function()
        return 'new setup'
      end,
    }
    lualine.setup(config)
    wait(100)
    eq(0, draws)
    assert(vim.o.statusline:find('new setup', 1, true))
  end)

  it('cancels a delayed batch when setup replaces the configuration', function()
    request()
    assert(vim.wait(30, function()
      return draws == 1
    end, 1))
    request()
    local new_draws = 0
    config.sections.lualine_a = {
      function()
        new_draws = new_draws + 1
        return 'replacement'
      end,
    }
    config.options.refresh.refresh_time = 1000
    lualine.setup(config)
    wait(180)
    eq(1, draws)
    eq(1, new_draws)
  end)

  it('accepts requests raised while loading components during setup', function()
    local loader = require('lualine.utils.loader')
    local load_all = loader.load_all
    loader.load_all = function(...)
      request()
      return load_all(...)
    end
    local ok, err = pcall(lualine.setup, config)
    loader.load_all = load_all
    assert(ok, err)
    assert(vim.wait(100, function()
      return draws > 0
    end, 1))
  end)
end)
