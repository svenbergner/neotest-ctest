local config = require("neotest-ctest.config")
local logger = require("neotest.logging")

---@type neotest.Adapter
local adapter = { name = "neotest-ctest" }

local ctest_testcases_by_root = {}
local ctest_session_by_root = {}
local test_results_by_id = {}
local filter_unavailable_position_list

adapter.setup = function(user_config)
  config.setup(user_config)
  ctest_testcases_by_root = {}
  ctest_session_by_root = {}
  test_results_by_id = {}
  return adapter
end

function adapter.clear_cache()
  ctest_testcases_by_root = {}
  ctest_session_by_root = {}
  test_results_by_id = {}
end

function adapter.root(dir)
  return config.root(dir)
end

function adapter.filter_dir(name, rel_path, root)
  return config.filter_dir(name, rel_path, root)
end

local function ctest_root_for_path(path, position)
  local cwd = vim.loop.cwd()
  local root = adapter.root(path) or cwd
  return config.ctest_root(root, position or { id = path, name = vim.fn.fnamemodify(path, ":t"), path = path, type = "file" }) or root
end

local function ctest_testcases_for_root(root)
  if ctest_testcases_by_root[root] then
    return ctest_testcases_by_root[root]
  end

  -- Reuse a cached CTest session for this root (if any) to avoid re-running
  -- `ctest --version` on every call (e.g. once per file during discovery when
  -- `hide_unavailable_tests` is enabled).
  local ctest = ctest_session_by_root[root]
  if not ctest then
    local ok, created = pcall(function()
      return require("neotest-ctest.ctest"):new(root)
    end)
    if not ok then
      logger.warn("neotest-ctest: failed to load CTest tests for discovery: " .. tostring(created))
      ctest_testcases_by_root[root] = {}
      return ctest_testcases_by_root[root]
    end
    ctest = created
    ctest_session_by_root[root] = ctest
  end

  ctest_testcases_by_root[root] = ctest:testcases()
  return ctest_testcases_by_root[root]
end

local function has_available_positions(path)
  logger.debug("neotest-ctest: has_available_positions() start: " .. path)
  local start_time = vim.loop.hrtime()

  local framework = require("neotest-ctest.framework").detect(path)
  if not framework then
    logger.debug("neotest-ctest: has_available_positions() no framework detected: " .. path)
    return false
  end

  local ok, tree = pcall(framework.parse_positions, path)
  if not ok or not tree then
    logger.debug("neotest-ctest: has_available_positions() failed to parse positions: " .. path)
    return false
  end

  local root = ctest_root_for_path(path, tree:data())
  local testcases = ctest_testcases_for_root(root)
  local result = filter_unavailable_position_list(tree:to_list(), testcases) ~= nil

  local elapsed_ms = (vim.loop.hrtime() - start_time) / 1e6
  logger.debug(
    "neotest-ctest: has_available_positions() finished in "
      .. string.format("%.2f", elapsed_ms)
      .. "ms, result="
      .. tostring(result)
      .. ": "
      .. path
  )

  return result
end

function adapter.is_test_file(file_path)
  if not config.is_test_file(file_path) then
    return false
  end

  if not config.hide_unavailable_tests then
    return true
  end

  return has_available_positions(file_path)
end

local function has_prefixed_ctest_test(testcases, prefix)
  local ctest_prefix = prefix .. "/"
  for name, _ in pairs(testcases) do
    if vim.startswith(name, ctest_prefix) then
      return true
    end
  end
  return false
end

function filter_unavailable_position_list(position_list, testcases, parent_ctest_name, section_path)
  local position = position_list[1]
  local filtered = { position }

  local current_ctest_name = parent_ctest_name
  local current_section_path = section_path
  local available = true

  if position.type == "test" then
    if position.section_filter then
      current_section_path = section_path and (section_path .. "/" .. position.section_filter) or nil
      available = (current_section_path and testcases[current_section_path])
        or (parent_ctest_name and testcases[parent_ctest_name])
        or false
    else
      current_ctest_name = position.name
      current_section_path = position.name
      available = testcases[position.name] or has_prefixed_ctest_test(testcases, position.name)
    end
  end

  for index = 2, #position_list do
    local child = filter_unavailable_position_list(
      position_list[index],
      testcases,
      current_ctest_name,
      current_section_path
    )
    if child then
      table.insert(filtered, child)
    end
  end

  if position.type == "file" or position.type == "namespace" then
    if #filtered > 1 then
      return filtered
    end

    return nil
  end

  if available or #filtered > 1 then
    return filtered
  end

  return nil
end

local function filter_unavailable_positions(tree, path)
  if not config.hide_unavailable_tests then
    return tree
  end

  local root = ctest_root_for_path(path, tree:data())
  local testcases = ctest_testcases_for_root(root)
  local filtered = filter_unavailable_position_list(tree:to_list(), testcases)
  if not filtered then
    return nil
  end

  local Tree = require("neotest.types").Tree
  return Tree.from_list(filtered, function(position)
    return position.id
  end)
end

function adapter.discover_positions(path)
  logger.debug("neotest-ctest: discover_positions() start: " .. path)
  local start_time = vim.loop.hrtime()

  local framework = require("neotest-ctest.framework").detect(path)
  if not framework then
    logger.error("Failed to detect test framework for file: " .. path)
    return
  end

  local detect_elapsed_ms = (vim.loop.hrtime() - start_time) / 1e6
  logger.debug(
    "neotest-ctest: discover_positions() framework detected in "
      .. string.format("%.2f", detect_elapsed_ms)
      .. "ms: "
      .. path
  )

  local parse_start_time = vim.loop.hrtime()
  local tree = framework.parse_positions(path)
  local parse_elapsed_ms = (vim.loop.hrtime() - parse_start_time) / 1e6
  logger.debug(
    "neotest-ctest: discover_positions() parse_positions() finished in "
      .. string.format("%.2f", parse_elapsed_ms)
      .. "ms: "
      .. path
  )

  local filter_start_time = vim.loop.hrtime()
  local result = filter_unavailable_positions(tree, path)
  local filter_elapsed_ms = (vim.loop.hrtime() - filter_start_time) / 1e6
  logger.debug(
    "neotest-ctest: discover_positions() filter_unavailable_positions() finished in "
      .. string.format("%.2f", filter_elapsed_ms)
      .. "ms: "
      .. path
  )

  local total_elapsed_ms = (vim.loop.hrtime() - start_time) / 1e6
  logger.debug(
    "neotest-ctest: discover_positions() finished in "
      .. string.format("%.2f", total_elapsed_ms)
      .. "ms: "
      .. path
  )

  return result
end

local function section_ctest_name(tree_node)
  local data = tree_node and tree_node:data()
  if not data or not data.section_filter then
    return nil
  end

  local parts = { data.section_filter }
  local parent = tree_node:parent()
  while parent do
    local parent_data = parent:data()
    if parent_data.type == "test" then
      if parent_data.section_filter then
        table.insert(parts, 1, parent_data.section_filter)
      else
        table.insert(parts, 1, parent_data.name)
        return table.concat(parts, "/")
      end
    end
    parent = parent:parent()
  end

  return nil
end

local function add_runnable_test(runnable_tests, seen_runnable_tests, testcase)
  if not testcase then
    return
  end

  local key = testcase.index or testcase
  if seen_runnable_tests[key] then
    return
  end

  seen_runnable_tests[key] = true
  table.insert(runnable_tests, testcase)
end

local function add_prefixed_ctest_tests(runnable_tests, seen_runnable_tests, testcases, prefix)
  local ctest_prefix = prefix .. "/"
  local names = vim.tbl_keys(testcases)
  table.sort(names)
  for _, name in ipairs(names) do
    local testcase = testcases[name]
    if vim.startswith(name, ctest_prefix) then
      add_runnable_test(runnable_tests, seen_runnable_tests, testcase)
    end
  end
end

local function collect_runnable_tests(tree, testcases)
  local runnable_tests = {}
  local seen_runnable_tests = {}
  local section_to_ctest = {}

  for _, node in tree:iter() do
    if node.type == "test" then
      if testcases[node.name] then
        -- Top-level TEST_CASE / TEST_CASE_METHOD / SCENARIO known to CTest
        add_runnable_test(runnable_tests, seen_runnable_tests, testcases[node.name])
      elseif not node.section_filter then
        add_prefixed_ctest_tests(runnable_tests, seen_runnable_tests, testcases, node.name)
      else
        local tree_node = tree:get_key(node.id)
        local ctest_section_name = section_ctest_name(tree_node)
        if ctest_section_name and testcases[ctest_section_name] then
          add_runnable_test(runnable_tests, seen_runnable_tests, testcases[ctest_section_name])
          section_to_ctest[node.id] = ctest_section_name
        end

        -- SECTION node: not directly known to CTest.
        -- Find the nearest ancestor TEST_CASE and record the mapping.
        local ancestor = tree_node and tree_node:parent()
        while ancestor do
          local adata = ancestor:data()
          if adata.type == "test" and testcases[adata.name] then
            section_to_ctest[node.id] = adata.name
            add_runnable_test(runnable_tests, seen_runnable_tests, testcases[adata.name])
            break
          end
          ancestor = ancestor:parent()
        end
      end
    end
  end

  return runnable_tests, section_to_ctest
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
  root = config.ctest_root(root, position) or root
  local ctest_module = require("neotest-ctest.ctest")
  local ctest = ctest_module:new(root)

  local framework = require("neotest-ctest.framework").detect(position.path)
  if not framework then
    logger.error("neotest-ctest: Failed to detect test framework for file: " .. position.path)
    return nil
  end

  -- Collect runnable tests (known to CTest)
  local testcases = ctest:testcases()
  local runnable_tests, section_to_ctest = collect_runnable_tests(tree, testcases)

  if #runnable_tests == 0 then
    for _, test_dir in ipairs(ctest_module:test_dirs(root)) do
      if test_dir ~= ctest._test_dir then
        local candidate = ctest_module:new(root, test_dir)
        local candidate_testcases = candidate:testcases()
        local candidate_runnable_tests, candidate_section_to_ctest =
          collect_runnable_tests(tree, candidate_testcases)
        if #candidate_runnable_tests > 0 then
          ctest = candidate
          testcases = candidate_testcases
          runnable_tests = candidate_runnable_tests
          section_to_ctest = candidate_section_to_ctest
          break
        end
      end
    end
  end

  -- Catch2 -c section filter chain (only set when running a single SECTION node)
  local section_args = {}
  -- Full Catch2 JUnit lookup key for a directly-run SECTION, e.g. "TestCase/Outer/Inner".
  -- Catch2 JUnit uses "TestCase/Section" as the <testcase name> attribute when sections
  -- are involved, so we can't look up results by just the CTest test name.
  local section_junit_key = nil

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

    -- Fallback: range-containment search failed (e.g. file changed or testcases is empty).
    -- Traverse the neotest position tree via the shared _nodes map to find the CTest ancestor.
    if not ctest_ancestor then
      local parent_node = tree:get_key(position.id)
      parent_node = parent_node and parent_node:parent()
      while parent_node do
        local pdata = parent_node:data()
        if pdata.type == "test" and testcases[pdata.name] then
          logger.debug(
            "neotest-ctest: SECTION — found CTest ancestor via tree traversal: " .. pdata.name
          )
          ctest_ancestor = pdata
          break
        end
        parent_node = parent_node:parent()
      end
    end

    if not ctest_ancestor then
      for _, node in full_tree:iter() do
        if node.type == "test" and testcases[node.name] and node.path == position.path and node.range and node.range[1] <= position.range[1] then
          if not ctest_ancestor or node.range[1] > ctest_ancestor.range[1] then
            ctest_ancestor = node
          end
        end
      end
      if ctest_ancestor then
        logger.debug("neotest-ctest: SECTION — found CTest ancestor via preceding test fallback: " .. ctest_ancestor.name)
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

    local strategy = vim.tbl_deep_extend("force", {
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
    }, config.dap_args or {})

    return {
      command = command,
      strategy = strategy,
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

local function single_testcase(testsuite)
  local only = nil
  for name, testcase in pairs(testsuite) do
    if name ~= "summary" then
      if only then
        return nil
      end
      only = testcase
    end
  end
  return only
end

local function is_passed_status(status)
  return status == "run" or status == "passed" or status == "pass"
end

local function is_failed_status(status)
  return status == "fail" or status == "failed" or status == "failure"
end

local function is_skipped_status(status)
  return status == "skipped" or status == "disabled" or status == "notrun"
end

local function prepare_results(tree, testsuite, framework, context)
  local node = tree:data()
  local results = {}

  if node.type == "file" or node.type == "namespace" then
    local passed = 0
    local failed = 0
    local skipped = 0
    for _, child in pairs(tree:children()) do
      local r = prepare_results(child, testsuite, framework, context)
      for n, v in pairs(r) do
        results[n] = v
        if v.status == "passed" then
          passed = passed + 1
        elseif v.status == "failed" then
          failed = failed + 1
        elseif v.status == "skipped" then
          skipped = skipped + 1
        end
      end
    end

    local status = failed > 0 and "failed" or passed > 0 and "passed" or skipped > 0 and "skipped" or nil
    if status then
      results[node.id] = { status = status, output = testsuite.summary.output }
    end
  elseif node.type == "test" then
    -- For SECTION nodes (Catch2), fall back to the parent CTest test result.
    -- When running directly (catch2_direct), Catch2 JUnit uses "TestCase/Section" as the
    -- <testcase name>, so look up by the pre-computed section_junit_key first.
    local testcase = testsuite[node.name]
    local using_section_fallback = false
    if not testcase and context then
      if context.catch2_direct and context.section_junit_key then
        testcase = testsuite[context.section_junit_key]
      end
      if not testcase and context.section_to_ctest then
        local parent_name = context.section_to_ctest[node.id]
        if parent_name then
          testcase = testsuite[parent_name]
          if not testcase and context.root_testcase then
            testcase = context.root_testcase
          end
          using_section_fallback = true
        end
      end
      if not testcase and context.root_id == node.id then
        testcase = context.root_testcase
      end
    end

    if not testcase then
      logger.warn(string.format("Unknown CTest testcase '%s' (leaving previous status unchanged)", node.name))
    else
      if is_passed_status(testcase.status) then
        results[node.id] = {
          status = "passed",
          short = ("Passed in %.6f seconds"):format(testcase.time),
          output = testsuite.summary.output,
        }
      elseif is_failed_status(testcase.status) then
        local errors = framework.parse_errors(testcase.output)

        if using_section_fallback then
          -- When inheriting from the parent CTest result, mark only SECTIONs with
          -- matching error lines as failed. Sibling SECTIONs with no matching errors
          -- did run successfully, so report them as passed instead of skipped.
          local section_errors = {}
          for _, error in ipairs(errors) do
            local adjusted_line = error.line - 1 -- convert to 0-indexed (neotest adds 1)
            if node.range[1] <= adjusted_line and adjusted_line <= node.range[3] then
              table.insert(section_errors, { line = adjusted_line, message = error.message })
            end
          end
          if #section_errors > 0 then
            results[node.id] = {
              status = "failed",
              short = testcase.output,
              output = testsuite.summary.output,
              errors = section_errors,
            }
          elseif #errors > 0 then
            results[node.id] = {
              status = "passed",
              short = ("Passed in %.6f seconds"):format(testcase.time),
              output = testsuite.summary.output,
            }
          end
        else
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
        end
      else
        if is_skipped_status(testcase.status) and not using_section_fallback then
          results[node.id] = { status = "skipped" }
        end
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

local function aggregate_parent_status(results)
  local has_skipped = false
  local status = nil
  for _, v in pairs(results) do
    if v.status == "failed" then
      return "failed"
    elseif v.status == "passed" then
      status = "passed"
    elseif v.status == "skipped" then
      has_skipped = true
    end
  end

  -- A run that only produced skipped leaf results must not overwrite the
  -- previous result of the enclosing file/namespace. Otherwise a single skipped
  -- Catch2/CTest case makes the complete branch look skipped in neotest.
  if status then
    return status
  elseif has_skipped then
    return nil
  end

  return nil
end

local function result_status(result)
  return result and result.status or nil
end

local function aggregate_known_statuses(statuses)
  local has_passed = false
  local has_skipped = false
  for _, status in ipairs(statuses) do
    if status == "failed" then
      return "failed"
    elseif status == "passed" then
      has_passed = true
    elseif status == "skipped" then
      has_skipped = true
    end
  end

  if has_passed then
    return "passed"
  elseif has_skipped then
    return nil
  end

  return nil
end

local function aggregate_cached_subtree_status(tree, visited)
  local node = tree:data()
  visited = visited or {}
  if visited[node.id] then
    return nil
  end
  visited[node.id] = true

  local child_statuses = {}

  for _, child in pairs(tree:children()) do
    local status = aggregate_cached_subtree_status(child, visited)
    if status then
      table.insert(child_statuses, status)
    end
  end

  local child_status = aggregate_known_statuses(child_statuses)
  if child_status then
    return child_status
  end

  return result_status(test_results_by_id[node.id])
end

local function add_descendant_section_results(results, root_node, framework, status, testsuite)
  if root_node.type ~= "test" or root_node.section_filter or status ~= "passed" then
    return
  end

  local has_children = false
  local ok, full_tree = pcall(framework.parse_positions, root_node.path)
  if not ok or not full_tree then
    return
  end

  for _, node in full_tree:iter() do
    if
      node.id ~= root_node.id
      and node.type == "test"
      and node.section_filter
      and node.path == root_node.path
      and node.range
      and root_node.range
      and root_node.range[1] <= node.range[1]
      and node.range[3] <= root_node.range[3]
    then
      has_children = true
      results[node.id] = {
        status = "passed",
        output = testsuite.summary.output,
      }
    end
  end

  if has_children and results[root_node.id] then
    results[root_node.id].status = status
  end
end

function adapter.results(spec, _, tree)
  local context = spec.context
  local testsuite = context.catch2_direct
    and context.ctest:parse_catch2_direct_results()
    or context.ctest:parse_test_results()
  context.root_id = tree:data().id
  context.root_testcase = single_testcase(testsuite)

  local results = prepare_results(tree, testsuite, context.framework, context)
  local root_result = results[context.root_id]
  if root_result then
    add_descendant_section_results(results, tree:data(), context.framework, root_result.status, testsuite)
  end

  for id, result in pairs(results) do
    test_results_by_id[id] = result
  end

  -- When running a single test, prepare_results only covers the subtree rooted at
  -- that test node. Neotest's runner propagates results only within the subtree, so
  -- ancestor nodes keep stale results from previous runs (e.g. parent stays
  -- "failed" after a test is fixed and re-runs as "passed").
  -- Fix: walk up tree:parent() and recompute each ancestor from current results
  -- plus the last known sibling results.
  local status = aggregate_parent_status(results)

  local parent = tree:parent()
  while parent do
    local pdata = parent:data()
    if status and pdata.id and not results[pdata.id] then
      local parent_status = aggregate_cached_subtree_status(parent)
      if parent_status then
        results[pdata.id] = { status = parent_status, output = testsuite.summary.output }
        test_results_by_id[pdata.id] = results[pdata.id]
      end
    end
    parent = parent:parent()
  end

  return results
end

return adapter
