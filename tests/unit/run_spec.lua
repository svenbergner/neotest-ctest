local assert = require("luassert")
local adapter = require("neotest-ctest")
local ctest = require("neotest-ctest.ctest")
local framework = require("neotest-ctest.framework")
local Tree = require("neotest.types").Tree

describe("adapter.build_spec", function()
  local original_ctest_new
  local original_ctest_test_dirs
  local original_framework_detect

  before_each(function()
    adapter.setup({
      root = function(_)
        return "/project"
      end,
      ctest_root = function(root, _)
        return root
      end,
    })

    original_ctest_new = ctest.new
    original_ctest_test_dirs = ctest.test_dirs
    original_framework_detect = framework.detect
  end)

  after_each(function()
    ctest.new = original_ctest_new
    ctest.test_dirs = original_ctest_test_dirs
    framework.detect = original_framework_detect
    adapter.setup({})
  end)

  it("runs CTest SECTION entries when the selected TEST_CASE has no direct CTest entry", function()
    ctest.new = function(_)
      return {
        testcases = function()
          return {
            ["With sections/First section"] = { index = 3 },
            ["With sections/Second section"] = { index = 4 },
          }
        end,
        command = function(_, args)
          local command = { "ctest" }
          vim.list_extend(command, args)
          return command
        end,
      }
    end

    framework.detect = function(_)
      return {
        parse_errors = function(_)
          return {}
        end,
      }
    end

    local test_file = "TEST_CASE_SECTION_test.cpp"
    local tree = Tree.from_list({
      {
        id = test_file .. "::With sections",
        name = "With sections",
        path = test_file,
        range = { 4, 0, 11, 1 },
        type = "test",
      },
      {
        {
          id = test_file .. "::With sections::First section",
          name = "First section",
          path = test_file,
          range = { 5, 2, 7, 3 },
          type = "test",
          section_filter = "First section",
        },
      },
      {
        {
          id = test_file .. "::With sections::Second section",
          name = "Second section",
          path = test_file,
          range = { 8, 2, 10, 3 },
          type = "test",
          section_filter = "Second section",
        },
      },
    }, function(pos)
      return pos.id
    end)

    local spec = adapter.build_spec({ tree = tree })

    assert.is_not_nil(spec)
    assert.are.same({ "ctest", "-I", "0,0,0,3,4" }, spec.command)
    assert.equals(
      "With sections/First section",
      spec.context.section_to_ctest[test_file .. "::With sections::First section"]
    )
    assert.equals(
      "With sections/Second section",
      spec.context.section_to_ctest[test_file .. "::With sections::Second section"]
    )
  end)

  it("runs prefixed CTest entries when the selected TEST_CASE tree has no SECTION children", function()
    ctest.new = function(_)
      return {
        testcases = function()
          return {
            ["With sections/First section"] = { index = 3 },
            ["With sections/Second section"] = { index = 4 },
            ["Other test/First section"] = { index = 5 },
          }
        end,
        command = function(_, args)
          local command = { "ctest" }
          vim.list_extend(command, args)
          return command
        end,
      }
    end

    framework.detect = function(_)
      return {
        parse_errors = function(_)
          return {}
        end,
      }
    end

    local test_file = "TEST_CASE_SECTION_test.cpp"
    local tree = Tree.from_list({
      {
        id = test_file .. "::With sections",
        name = "With sections",
        path = test_file,
        range = { 4, 0, 11, 1 },
        type = "test",
      },
    }, function(pos)
      return pos.id
    end)

    local spec = adapter.build_spec({ tree = tree })

    assert.is_not_nil(spec)
    assert.are.same({ "ctest", "-I", "0,0,0,3,4" }, spec.command)
  end)

  it("uses another CTest directory when the first one does not contain the selected test", function()
    ctest.test_dirs = function(_)
      return { "/build/stale", "/build/current" }
    end

    ctest.new = function(_, _, test_dir)
      local selected_dir = test_dir or "/build/stale"
      local testcases = {}
      if selected_dir == "/build/current" then
        testcases["With sections"] = { index = 7 }
      end

      return {
        _test_dir = selected_dir,
        testcases = function()
          return testcases
        end,
        command = function(self, args)
          local command = { "ctest", "--test-dir", self._test_dir }
          vim.list_extend(command, args)
          return command
        end,
      }
    end

    framework.detect = function(_)
      return {
        parse_errors = function(_)
          return {}
        end,
      }
    end

    local test_file = "TEST_CASE_SECTION_test.cpp"
    local tree = Tree.from_list({
      {
        id = test_file .. "::With sections",
        name = "With sections",
        path = test_file,
        range = { 4, 0, 11, 1 },
        type = "test",
      },
    }, function(pos)
      return pos.id
    end)

    local spec = adapter.build_spec({ tree = tree })

    assert.is_not_nil(spec)
    assert.are.same({ "ctest", "--test-dir", "/build/current", "-I", "0,0,0,7" }, spec.command)
  end)
end)

describe("adapter.discover_positions", function()
  local original_ctest_new
  local original_framework_detect

  before_each(function()
    adapter.setup({
      hide_unavailable_tests = true,
      root = function(_)
        return "/project"
      end,
      ctest_root = function(root, _)
        return root
      end,
    })

    original_ctest_new = ctest.new
    original_framework_detect = framework.detect
  end)

  after_each(function()
    ctest.new = original_ctest_new
    framework.detect = original_framework_detect
    adapter.setup({})
  end)

  it("filters tests that are not registered in CTest", function()
    local test_file = "TEST_CASE_test.cpp"
    local parsed_tree = Tree.from_list({
      {
        id = test_file,
        name = test_file,
        path = test_file,
        range = { 0, 0, 20, 0 },
        type = "file",
      },
      {
        {
          id = test_file .. "::Available",
          name = "Available",
          path = test_file,
          range = { 2, 0, 4, 1 },
          type = "test",
        },
      },
      {
        {
          id = test_file .. "::Unavailable",
          name = "Unavailable",
          path = test_file,
          range = { 6, 0, 8, 1 },
          type = "test",
        },
      },
    }, function(pos)
      return pos.id
    end)

    framework.detect = function(_)
      return {
        parse_positions = function(_)
          return parsed_tree
        end,
      }
    end

    ctest.new = function(_)
      return {
        testcases = function()
          return {
            Available = { index = 1 },
          }
        end,
      }
    end

    local positions = adapter.discover_positions(test_file):to_list()

    assert.equals(2, #positions)
    assert.equals("Available", positions[2][1].name)
  end)

  it("filters empty namespace containers", function()
    local test_file = "TEST_CASE_NAMESPACE_test.cpp"
    local parsed_tree = Tree.from_list({
      {
        id = test_file,
        name = test_file,
        path = test_file,
        range = { 0, 0, 20, 0 },
        type = "file",
      },
      {
        {
          id = test_file .. "::Namespace",
          name = "Namespace",
          path = test_file,
          range = { 1, 0, 10, 1 },
          type = "namespace",
        },
        {
          {
            id = test_file .. "::Namespace::Unavailable",
            name = "Unavailable",
            path = test_file,
            range = { 3, 0, 5, 1 },
            type = "test",
          },
        },
      },
      {
        {
          id = test_file .. "::Available",
          name = "Available",
          path = test_file,
          range = { 12, 0, 14, 1 },
          type = "test",
        },
      },
    }, function(pos)
      return pos.id
    end)

    framework.detect = function(_)
      return {
        parse_positions = function(_)
          return parsed_tree
        end,
      }
    end

    ctest.new = function(_)
      return {
        testcases = function()
          return {
            Available = { index = 1 },
          }
        end,
      }
    end

    local positions = adapter.discover_positions(test_file):to_list()

    assert.equals(2, #positions)
    assert.equals("Available", positions[2][1].name)
  end)

  it("returns nil when no tests are registered in CTest", function()
    local test_file = "TEST_CASE_test.cpp"
    local parsed_tree = Tree.from_list({
      {
        id = test_file,
        name = test_file,
        path = test_file,
        range = { 0, 0, 20, 0 },
        type = "file",
      },
      {
        {
          id = test_file .. "::Unavailable",
          name = "Unavailable",
          path = test_file,
          range = { 2, 0, 4, 1 },
          type = "test",
        },
      },
    }, function(pos)
      return pos.id
    end)

    framework.detect = function(_)
      return {
        parse_positions = function(_)
          return parsed_tree
        end,
      }
    end

    ctest.new = function(_)
      return {
        testcases = function()
          return {}
        end,
      }
    end

    assert.is_nil(adapter.discover_positions(test_file))
  end)

  it("keeps SECTION children when their parent TEST_CASE is registered in CTest", function()
    local test_file = "TEST_CASE_SECTION_test.cpp"
    local parsed_tree = Tree.from_list({
      {
        id = test_file,
        name = test_file,
        path = test_file,
        range = { 0, 0, 20, 0 },
        type = "file",
      },
      {
        {
          id = test_file .. "::With sections",
          name = "With sections",
          path = test_file,
          range = { 2, 0, 12, 1 },
          type = "test",
        },
        {
          {
            id = test_file .. "::With sections::First section",
            name = "First section",
            path = test_file,
            range = { 4, 2, 6, 3 },
            type = "test",
            section_filter = "First section",
          },
        },
      },
    }, function(pos)
      return pos.id
    end)

    framework.detect = function(_)
      return {
        parse_positions = function(_)
          return parsed_tree
        end,
      }
    end

    ctest.new = function(_)
      return {
        testcases = function()
          return {
            ["With sections"] = { index = 1 },
          }
        end,
      }
    end

    local positions = adapter.discover_positions(test_file):to_list()

    assert.equals("With sections", positions[2][1].name)
    assert.equals("First section", positions[2][2][1].name)
  end)
end)

describe("adapter.is_test_file with hide_unavailable_tests", function()
  local original_ctest_new
  local original_framework_detect

  before_each(function()
    adapter.setup({
      hide_unavailable_tests = true,
      is_test_file = function(_)
        return true
      end,
      root = function(_)
        return "/project"
      end,
      ctest_root = function(root, _)
        return root
      end,
    })

    original_ctest_new = ctest.new
    original_framework_detect = framework.detect
  end)

  after_each(function()
    ctest.new = original_ctest_new
    framework.detect = original_framework_detect
    adapter.setup({})
  end)

  it("returns false when the file has no CTest-registered tests", function()
    local test_file = "TEST_CASE_test.cpp"
    local parsed_tree = Tree.from_list({
      {
        id = test_file,
        name = test_file,
        path = test_file,
        range = { 0, 0, 20, 0 },
        type = "file",
      },
      {
        {
          id = test_file .. "::Unavailable",
          name = "Unavailable",
          path = test_file,
          range = { 2, 0, 4, 1 },
          type = "test",
        },
      },
    }, function(pos)
      return pos.id
    end)

    framework.detect = function(_)
      return {
        parse_positions = function(_)
          return parsed_tree
        end,
      }
    end

    ctest.new = function(_)
      return {
        testcases = function()
          return {}
        end,
      }
    end

    assert.is_false(adapter.is_test_file(test_file))
  end)

  it("returns true when the file has a CTest-registered test", function()
    local test_file = "TEST_CASE_test.cpp"
    local parsed_tree = Tree.from_list({
      {
        id = test_file,
        name = test_file,
        path = test_file,
        range = { 0, 0, 20, 0 },
        type = "file",
      },
      {
        {
          id = test_file .. "::Available",
          name = "Available",
          path = test_file,
          range = { 2, 0, 4, 1 },
          type = "test",
        },
      },
    }, function(pos)
      return pos.id
    end)

    framework.detect = function(_)
      return {
        parse_positions = function(_)
          return parsed_tree
        end,
      }
    end

    ctest.new = function(_)
      return {
        testcases = function()
          return {
            Available = { index = 1 },
          }
        end,
      }
    end

    assert.is_true(adapter.is_test_file(test_file))
  end)
end)
