-- run_cmd_async_spec.lua: direct unit tests for adapters.run_cmd_async.
--
-- Every adapter's get_schema_batch_async goes through this one function, but
-- nothing exercised it directly until now -- only indirectly, one adapter at
-- a time, via adapter_spec.lua's argv-parity tests. These tests target the
-- function itself: real content delivery (a real subprocess, not a mock), a
-- real ENOENT spawn, and the watchdog's exactly-once guarantee.

local adapters = require("dadbod-grip.adapters")

local pass = 0
local fail = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local function contains(s, pattern, msg)
  assert(s:find(pattern, 1, true), (msg or "") .. ": expected '" .. tostring(s) .. "' to contain '" .. pattern .. "'")
end

-- ── happy path: a real subprocess, not a mock ───────────────────────────────
-- Confirms the actual delivery, not just that *some* callback ran: stdout,
-- stderr and the exit code all have to survive the round trip through
-- vim.system + vim.schedule unchanged.

test("run_cmd_async: real spawn delivers stdout/stderr/code, asynchronously", function()
  local done, got = false, nil
  adapters.run_cmd_async({ "sh", "-c", "printf out; printf err 1>&2; exit 3" }, 5000,
    function(stdout, stderr, code)
      got = { stdout = stdout, stderr = stderr, code = code }
      done = true
    end)
  eq(done, false, "callback must not fire on the calling tick")
  vim.wait(2000, function() return done end, 1)
  assert(done, "callback never fired")
  eq(got.stdout, "out", "stdout delivered")
  eq(got.stderr, "err", "stderr delivered")
  eq(got.code, 3, "exit code delivered")
end)

-- ── ENOENT: a genuinely missing executable, not a mocked throw ─────────────
-- vim.system() raises synchronously when the executable can't be found;
-- run_cmd_async promises to pcall that away and report it like a failed run
-- instead of letting the exception escape into a caller with no pcall of
-- its own (get_schema_batch_async callers, in particular).

test("run_cmd_async: a real nonexistent executable does not throw", function()
  local done, got = false, nil
  local ok, err = pcall(function()
    adapters.run_cmd_async({ "dadbod-grip-test-nonexistent-cmd-93hjfd" }, 5000,
      function(stdout, stderr, code)
        got = { stdout = stdout, stderr = stderr, code = code }
        done = true
      end)
  end)
  assert(ok, "run_cmd_async must never throw for a missing executable: " .. tostring(err))
  eq(done, false, "callback must not fire on the calling tick")
  vim.wait(2000, function() return done end, 1)
  assert(done, "callback never fired")
  eq(got.code, 1, "missing executable reports a failed exit")
  contains(got.stderr, "ENOENT", "stderr carries the spawn error")
end)

-- ── the watchdog: on_exit never arrives at all ──────────────────────────────
-- Mocked here (a real hung process would make this test as slow as the
-- timeout it's proving) -- vim.system's on_exit callback is simply never
-- invoked, so the watchdog is the only path to a delivered callback.

test("run_cmd_async: on_exit never firing still gets a timeout answer, once", function()
  local orig = vim.system
  local grace = adapters._exit_grace_ms
  local calls, got = 0, nil
  vim.system = function(_args, _opts, _cb)
    -- No on_exit call, ever.
    return { wait = function() end }
  end
  local ok, err = pcall(function()
    adapters._exit_grace_ms = 20
    adapters.run_cmd_async({ "hang" }, 10, function(stdout, stderr, code)
      calls = calls + 1
      got = { stdout = stdout, stderr = stderr, code = code }
    end)
    vim.wait(2000, function() return got ~= nil end, 1)
    assert(got, "watchdog must deliver a callback")
    eq(got.code, 1, "timeout reports a failed exit")
    eq(got.stderr, "command timed out", "same message as the blocking path's fallback")
    eq(got.stdout, "", "no output")
    eq(calls, 1, "delivered exactly once")
  end)
  adapters._exit_grace_ms = grace
  vim.system = orig
  if not ok then error(err) end
end)

-- ── on_exit DOES fire: no second, watchdog-driven call ──────────────────────

test("run_cmd_async: on_exit firing normally suppresses the watchdog", function()
  local orig = vim.system
  local grace = adapters._exit_grace_ms
  local calls = 0
  vim.system = function(_args, _opts, cb)
    vim.schedule(function() cb({ stdout = "ok", stderr = "", code = 0 }) end)
    return { wait = function() end }
  end
  local ok, err = pcall(function()
    adapters._exit_grace_ms = 20
    adapters.run_cmd_async({ "true" }, 10, function() calls = calls + 1 end)
    vim.wait(2000, function() return calls > 0 end, 1)
    eq(calls, 1, "delivered once via on_exit")
    -- Wait past the watchdog's deadline: a still-armed timer would fire again.
    vim.wait(300, function() return calls > 1 end, 1)
    eq(calls, 1, "the watchdog must not also deliver")
  end)
  adapters._exit_grace_ms = grace
  vim.system = orig
  if not ok then error(err) end
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\nrun_cmd_async_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
