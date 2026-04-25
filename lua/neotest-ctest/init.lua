local config = require("neotest-ctest.config")
local logger = require("neotest.logging")

---@type neotest.Adapter
local adapter = { name = "neotest-ctest" }

adapter.setup = function(user_config)
  config.setup(user_config)
  return adapter
end

function adapter.root(dir)
  return config.root(dir)
end

function adapter.filter_dir(name, rel_path, root)
  return config.filter_dir(name, rel_path, root)
end

function adapter.is_test_file(file_path)
  return config.is_test_file(file_path)
end

function adapter.discover_positions(path)
  local framework = require("neotest-ctest.framework").detect(path)
  if not framework then
    logger.error("Failed to detect test framework for file: " .. path)
    return
  end

  return framework.parse_positions(path)
end

---@param args neotest.RunArgs
function adapter.build_spec(args)
  local tree = args and args.tree
  if not tree then
    return
  end

  local supported_types = { "test", "namespace", "file" }
  local position = tree:data()
  if not vim.tbl_contains(supported_types, position.type) then
    return
  end

  local cwd = vim.loop.cwd()
  local root = adapter.root(position.path) or cwd
  local ctest = require("neotest-ctest.ctest"):new(root)

  local framework = require("neotest-ctest.framework").detect(position.path)
  if not framework then
    logger.error("neotest-ctest: Failed to detect test framework for file: " .. position.path)
    return nil
  end

  -- Collect runnable tests (known to CTest)
  local testcases = ctest:testcases()
  local runnable_tests = {}
  -- Maps section node id -> CTest test name (for sections nested inside a TEST_CASE)
  local section_to_ctest = {}
  -- Catch2 -c section filter chain (only set when running a single SECTION node)
  local section_args = {}
  -- Full Catch2 JUnit lookup key for a directly-run SECTION, e.g. "TestCase/Outer/Inner".
  -- Catch2 JUnit uses "TestCase/Section" as the <testcase name> attribute when sections
  -- are involved, so we can't look up results by just the CTest test name.
  local section_junit_key = nil

  for _, node in tree:iter() do
    if node.type == "test" then
      if testcases[node.name] then
        -- Top-level TEST_CASE / TEST_CASE_METHOD / SCENARIO known to CTest
        table.insert(runnable_tests, testcases[node.name])
      else
        -- SECTION node: not directly known to CTest.
        -- Find the nearest ancestor TEST_CASE and record the mapping.
        local ancestor = tree:get_key(node.id):parent()
        while ancestor do
          local adata = ancestor:data()
          if adata.type == "test" and testcases[adata.name] then
            section_to_ctest[node.id] = adata.name
            break
          end
          ancestor = ancestor:parent()
        end
      end
    end
  end

  -- When running a single SECTION node, build the Catch2 -c filter chain.
  -- args.tree is a subtree rooted at the selected SECTION, so :parent() is not
  -- available. Re-parse the full positions tree for the file and use range containment
  -- to find the enclosing TEST_CASE (CTest test) and any intermediate SECTION ancestors.
  if position.type == "test" and position.section_filter then
    local full_tree = framework.parse_positions(position.path)
    local ctest_ancestor = nil

    -- Find the innermost TEST_CASE whose range contains this SECTION
    for _, node in full_tree:iter() do
      if node.type == "test" and testcases[node.name] then
        if node.range[1] <= position.range[1] and node.range[3] >= position.range[3] then
          -- Prefer the innermost (latest start line) enclosing TEST_CASE
          if not ctest_ancestor or node.range[1] > ctest_ancestor.range[1] then
            ctest_ancestor = node
          end
        end
      end
    end

    if ctest_ancestor then
      logger.debug("neotest-ctest: SECTION — found CTest ancestor: " .. ctest_ancestor.name)
      table.insert(runnable_tests, testcases[ctest_ancestor.name])
      section_to_ctest[position.id] = ctest_ancestor.name

      -- Collect intermediate SECTION ancestors between the TEST_CASE and the selected
      -- SECTION (for nested sections), sorted outermost-first.
      local ancestors = {}
      for _, node in full_tree:iter() do
        if node.type == "test" and node.section_filter and node.id ~= position.id then
          if node.range[1] <= position.range[1] and node.range[3] >= position.range[3]
            and node.range[1] >= ctest_ancestor.range[1]
            and node.range[3] <= ctest_ancestor.range[3]
          then
            table.insert(ancestors, node)
          end
        end
      end
      table.sort(ancestors, function(a, b)
        return a.range[1] < b.range[1]
      end)

      for _, anc in ipairs(ancestors) do
        table.insert(section_args, "-c")
        table.insert(section_args, anc.section_filter)
      end
      table.insert(section_args, "-c")
      table.insert(section_args, position.section_filter)

      -- Build the JUnit lookup key: "TestCase/OuterSection/.../LeafSection".
      -- Catch2's JUnit reporter uses this slash-separated path as the <testcase name>.
      local path_parts = { ctest_ancestor.name }
      for _, anc in ipairs(ancestors) do
        table.insert(path_parts, anc.section_filter)
      end
      table.insert(path_parts, position.section_filter)
      section_junit_key = table.concat(path_parts, "/")
    else
      logger.warn(
        "neotest-ctest: SECTION — no CTest ancestor found for: " .. tostring(position.name)
      )
    end
  end

  -- If no runnable tests were resolved, bail out early to avoid producing an
  -- invalid CTest '-I' filter (e.g. "-I 0,0,0," with no indices).
  if #runnable_tests == 0 then
    logger.warn("neotest-ctest: no runnable tests found for the selected position")
    return nil
  end

  -- NOTE: The '-I Start,End,Stride,test#,test#,...' option runs the specified tests in the
  -- range starting from number Start, ending at number End, incremented by number Stride.
  -- If Start, End and Stride are set to 0, then CTest will run all test# as specified.
  local runnable_indices = vim.tbl_map(function(t)
    return t and t.index or nil
  end, runnable_tests)

  -- Build ctest_args as a proper table (one element per flag/value) so that
  -- ctest:command() returns a table-based command — no shell quoting issues.
  local ctest_args = { "-I", string.format("0,0,0,%s", table.concat(runnable_indices, ",")) }

  local extra_args = config.extra_args or {}
  vim.list_extend(extra_args, args.extra_args or {})
  vim.list_extend(ctest_args, extra_args)

  -- When SECTION filtering is needed, run the test executable directly instead of
  -- using CTest's --test-args (which is not available in all CTest versions).
  -- Build a command: <executable> [existing_args] <section_args> --reporter junit --out <path>
  if #section_args > 0 and args.strategy ~= "dap" then
    local dtest = runnable_tests[1]
    if dtest and dtest.executable then
      local direct_cmd = { dtest.executable }
      vim.list_extend(direct_cmd, dtest.args or {})
      vim.list_extend(direct_cmd, section_args)
      vim.list_extend(direct_cmd, { "--reporter", "junit", "--out", ctest._output_junit_path })
      return {
        command = direct_cmd,
        cwd = dtest.working_dir,
        env = next(dtest.env or {}) ~= nil and dtest.env or nil,
        context = {
          ctest = ctest,
          framework = framework,
          section_to_ctest = section_to_ctest,
          section_junit_key = section_junit_key,
          catch2_direct = true,
        },
      }
    end
    logger.warn(
      "neotest-ctest: No executable found for direct section execution; running full test case without section filter"
    )
  end

  local command = ctest:command(ctest_args)

  -- DAP strategy: launch the test executable directly under the debugger.
  -- Only supported when a single test is selected and dap_adapter is configured.
  if args.strategy == "dap" then
    local dap_adapter = config.dap_adapter
    if not dap_adapter then
      vim.notify(
        "neotest-ctest: DAP debugging requested but 'dap_adapter' is not configured. "
          .. "Set dap_adapter = 'codelldb' (or 'cppdbg') in the adapter setup.",
        vim.log.levels.ERROR
      )
      return nil
    end

    -- Find the first runnable test that has an executable
    local dap_test = nil
    for _, t in ipairs(runnable_tests) do
      if t and t.executable then
        dap_test = t
        break
      end
    end

    if not dap_test then
      vim.notify("neotest-ctest: No executable found for DAP debugging.", vim.log.levels.ERROR)
      return nil
    end

    return {
      command = command,
      strategy = {
        type = dap_adapter,
        request = "launch",
        name = "Debug CTest",
        program = dap_test.executable,
        args = vim.list_extend(vim.list_slice(dap_test.args or {}), section_args),
        cwd = dap_test.working_dir or root,
        stopAtEntry = false,
        -- codelldb uses `env` (flat table); cppdbg uses `environment` (array of {name,value})
        env = next(dap_test.env or {}) ~= nil and dap_test.env or nil,
        environment = (function()
          if not next(dap_test.env or {}) then return nil end
          local list = {}
          for k, v in pairs(dap_test.env) do
            table.insert(list, { name = k, value = v })
          end
          return list
        end)(),
      },
      context = {
        ctest = ctest,
        framework = framework,
        section_to_ctest = section_to_ctest,
      },
    }
  end

  return {
    command = command,
    context = {
      ctest = ctest,
      framework = framework,
      section_to_ctest = section_to_ctest,
    },
  }
end

local function prepare_results(tree, testsuite, framework, context)
  local node = tree:data()
  local results = {}

  if node.type == "file" or node.type == "namespace" then
    local passed = 0
    local failed = 0
    for _, child in pairs(tree:children()) do
      local r = prepare_results(child, testsuite, framework, context)
      for n, v in pairs(r) do
        results[n] = v
        if v.status == "passed" then
          passed = passed + 1
        elseif v.status == "failed" then
          failed = failed + 1
        end
      end
    end

    local status = failed > 0 and "failed" or passed > 0 and "passed" or "skipped"
    results[node.id] = { status = status, output = testsuite.summary.output }
  elseif node.type == "test" then
    -- For SECTION nodes (Catch2), fall back to the parent CTest test result.
    -- When running directly (catch2_direct), Catch2 JUnit uses "TestCase/Section" as the
    -- <testcase name>, so look up by the pre-computed section_junit_key first.
    local testcase = testsuite[node.name]
    if not testcase and context then
      if context.catch2_direct and context.section_junit_key then
        testcase = testsuite[context.section_junit_key]
      end
      if not testcase and context.section_to_ctest then
        local parent_name = context.section_to_ctest[node.id]
        if parent_name then
          testcase = testsuite[parent_name]
        end
      end
    end

    if not testcase then
      logger.warn(string.format("Unknown CTest testcase '%s' (marked as skipped)", node.name))
      results[node.id] = { status = "skipped" }
    else
      if testcase.status == "run" then
        results[node.id] = {
          status = "passed",
          short = ("Passed in %.6f seconds"):format(testcase.time),
          output = testsuite.summary.output,
        }
      elseif testcase.status == "fail" then
        local errors = framework.parse_errors(testcase.output)

        -- NOTE: Neotest adds 1 for some reason.
        for _, error in pairs(errors) do
          error.line = error.line - 1
        end

        results[node.id] = {
          status = "failed",
          short = testcase.output,
          output = testsuite.summary.output,
          errors = errors,
        }
      else
        results[node.id] = { status = "skipped" }
      end
    end

    -- Recurse into nested SECTION children (Catch2 nested_tests).
    -- Each child falls back to this test's CTest result via section_to_ctest.
    for _, child in pairs(tree:children()) do
      local r = prepare_results(child, testsuite, framework, context)
      for n, v in pairs(r) do
        results[n] = v
      end
    end
  end

  return results
end

function adapter.results(spec, _, tree)
  local context = spec.context
  local testsuite = context.catch2_direct
    and context.ctest:parse_catch2_direct_results()
    or context.ctest:parse_test_results()
  return prepare_results(tree, testsuite, context.framework, context)
end

return adapter
