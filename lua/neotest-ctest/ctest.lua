local config = require("neotest-ctest.config")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local nio = require("nio")

local ctest = {}

function ctest:run(args)
  local cmd = { unpack(config.cmd), "--test-dir", self._test_dir, unpack(args) }
  local _, result = lib.process.run(cmd, { stdout = true, stderr = true })

  return result.stdout
end

function ctest:new(cwd)
  local scandir = require("plenary.scandir")

  local ctest_roots = scandir.scan_dir(cwd, {
    respect_gitignore = false,
    depth = 3, -- NOTE: support multi-config projects
    search_pattern = "CTestTestfile.cmake",
    silent = true,
  })

  local test_dir = next(ctest_roots) and lib.files.parent(ctest_roots[1]) or nil

  if not test_dir then
    error("Failed to locate CTest test directory")
  end

  local version = self:run({ "--version" })

  if not version then
    error("Failed to determine CTest version")
  end

  local major, minor, _ = string.match(version, "(%d+)%.(%d+)%.(%d+)")
  major, minor = tonumber(major), tonumber(minor)
  if not ((major > 3) or (major >= 3 and minor >= 21)) then
    error("CTest version 3.21+ is required")
  end

  local output_junit_path = nio.fn.tempname()
  local output_log_path = nio.fn.tempname()

  local session = {
    _test_dir = test_dir,
    _output_junit_path = output_junit_path,
    _output_log_path = output_log_path,
  }
  setmetatable(session, self)
  self.__index = self
  return session
end

function ctest:command(args)
  args = args or {}
  local command = {
    "ctest",
    "--test-dir",
    self._test_dir,
    "--quiet",
    "--output-on-failure",
    "--output-junit",
    self._output_junit_path,
    "--output-log",
    self._output_log_path,
  }
  vim.list_extend(command, args)
  return command
end

function ctest:testcases()
  local testcases = {}

  local output = self:run({ "--show-only=json-v1" })

  if output then
    output = string.gsub(output, "[\n\r]", "")
    local decoded = vim.json.decode(output)

    for index, test in ipairs(decoded.tests) do
      local cmd = test.command or {}
      local env = {}
      local working_dir = nil

      for _, prop in ipairs(test.properties or {}) do
        if prop.name == "ENVIRONMENT_MODIFICATION" then
          -- value is an array of "VAR=operation:path" strings (CTest 3.22+)
          local mods = type(prop.value) == "table" and prop.value or { prop.value }
          for _, entry in ipairs(mods) do
            -- e.g. "DYLD_FRAMEWORK_PATH=path_list_prepend:/path/to/lib"
            local var, op, val = entry:match("^([^=]+)=([^:]+):(.+)$")
            if var and val then
              if op == "path_list_prepend" then
                local existing = os.getenv(var)
                env[var] = existing and (val .. ":" .. existing) or val
              elseif op == "path_list_append" then
                local existing = os.getenv(var)
                env[var] = existing and (existing .. ":" .. val) or val
              else -- "set", "unset", "string_prepend", etc.
                env[var] = val
              end
            end
          end
        elseif prop.name == "ENVIRONMENT" then
          -- simple "VAR=VALUE" list
          local entries = type(prop.value) == "table" and prop.value or { prop.value }
          for _, entry in ipairs(entries) do
            local var, val = entry:match("^([^=]+)=(.*)$")
            if var then
              env[var] = val or ""
            end
          end
        elseif prop.name == "WORKING_DIRECTORY" then
          working_dir = prop.value
        end
      end

      testcases[test.name] = {
        index = index,
        executable = cmd[1],
        args = vim.list_slice(cmd, 2),
        env = env,
        working_dir = working_dir,
      }
    end
  else
    -- TODO: log error?
  end

  return testcases
end

-- Parse Catch2 JUnit output produced by running the test executable directly
-- (i.e. without CTest) with `--reporter junit --out <path>`.
-- Catch2 JUnit has <testsuites> as root (vs CTest's <testsuite>), and uses
-- a <failure> child element to signal failures instead of status="fail".
function ctest:parse_catch2_direct_results()
  if vim.fn.filereadable(self._output_junit_path) == 0 then
    logger.error(
      "neotest-ctest: Catch2 JUnit output file not found: " .. tostring(self._output_junit_path)
    )
    return { summary = { tests = 0, failures = 0, skipped = 0, time = 0, output = "" } }
  end

  local junit_data = lib.files.read(self._output_junit_path)

  -- Catch2 may leave '>' unescaped in XML attribute values (e.g. section names that
  -- contain HTML like "<a href>").  neotest's xml2lua parser uses `[^>]-` to match
  -- tag content, so an unescaped '>' inside a quoted attribute value breaks parsing.
  -- Pre-process: escape literal '>' inside double-quoted attribute values.
  junit_data = junit_data:gsub('="([^"]*)"', function(val)
    return '="' .. val:gsub(">", "&gt;") .. '"'
  end)

  local junit = lib.xml.parse(junit_data)

  -- Catch2's JUnit reporter wraps everything in <testsuites><testsuite>
  local testsuite = junit.testsuites and junit.testsuites.testsuite or junit.testsuite

  if not testsuite then
    logger.error("neotest-ctest: Could not locate <testsuite> in Catch2 JUnit output")
    return { summary = { tests = 0, failures = 0, skipped = 0, time = 0, output = "" } }
  end

  local tests_count = tonumber(testsuite._attr.tests) or 0

  if not testsuite.testcase then
    logger.warn("neotest-ctest: Catch2 JUnit output contains no testcase elements")
    return { summary = { tests = 0, failures = 0, skipped = 0, time = 0, output = "" } }
  end

  -- lib.xml.parse returns a plain table (with _attr) for a single element, or a
  -- numeric array for multiple elements.  Catch2's <testsuite tests="N"> uses N =
  -- assertion count, not testcase count, so we cannot rely on tests_count < 2.
  local raw = testsuite.testcase._attr and { testsuite.testcase } or testsuite.testcase

  local results = {}
  local total_time = 0

  for _, testcase in pairs(raw) do
    local name = testcase._attr.name
    local time = tonumber(testcase._attr.time) or 0
    total_time = total_time + time

    local status, output
    if testcase.failure then
      status = "fail"
      local fail = testcase.failure
      -- failure may be a single element or a list
      if type(fail) == "table" and fail._attr then
        output = fail._attr.message or ""
      elseif type(fail) == "string" then
        output = fail
      else
        output = ""
      end
    else
      status = "run"
      output = testcase["system-out"] or ""
    end

    results[name] = { status = status, time = time, output = output }
  end

  results.summary = {
    tests = tests_count,
    failures = tonumber(testsuite._attr.failures) or 0,
    skipped = tonumber(testsuite._attr.skipped) or 0,
    time = total_time,
    output = self._output_junit_path,
  }

  return results
end

function ctest:parse_test_results()
  -- Guard: if CTest failed to produce the JUnit output file (e.g. command error,
  -- invalid args, or no tests ran), return an empty result set instead of crashing.
  if vim.fn.filereadable(self._output_junit_path) == 0 then
    logger.error(
      "neotest-ctest: JUnit output file not found: " .. tostring(self._output_junit_path)
        .. ". CTest may have failed to run. Check the output log: "
        .. tostring(self._output_log_path)
    )
    return { summary = { tests = 0, failures = 0, skipped = 0, time = 0, output = self._output_log_path } }
  end

  local junit_data = lib.files.read(self._output_junit_path)
  local junit = lib.xml.parse(junit_data)
  local testsuite = junit.testsuite
  local testcases = tonumber(testsuite._attr.tests) < 2 and { testsuite.testcase }
    or testsuite.testcase

  local results = {}

  -- NOTE: CTest doesn't seem to populate the testsuite._attr.time, so we'll have to
  -- compute it ourselves.
  local total_time = 0

  for _, testcase in pairs(testcases) do
    local name = testcase._attr.name
    local status = testcase._attr.status
    local time = tonumber(testcase._attr.time)
    total_time = total_time + time

    -- XXX: CTest only populates the "system-out"
    -- See: https://gitlab.kitware.com/cmake/cmake/-/issues/22478
    local output = testcase["system-out"]

    results[name] = {
      status = status,
      time = time,
      output = output,
    }
  end

  results.summary = {
    tests = tonumber(testsuite._attr.tests),
    failures = tonumber(testsuite._attr.failures),
    skipped = tonumber(testsuite._attr.skipped),
    time = total_time,
    output = self._output_log_path,
  }

  return results
end

return ctest
