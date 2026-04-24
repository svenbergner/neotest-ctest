local assert = require("luassert")
local catch2 = require("neotest-ctest.framework.catch2")
local it = require("nio").tests.it

describe("catch2.parse_positions", function()
  it("discovers TEST_CASE macro", function()
    local test_file = vim.loop.cwd() .. "/tests/unit/data/catch2/TEST_CASE_test.cpp"
    local actual_positions = catch2.parse_positions(test_file):to_list()
    local expected_positions = {
      {
        id = test_file,
        name = "TEST_CASE_test.cpp",
        path = test_file,
        range = { 0, 0, 12, 0 },
        type = "file",
      },
      {
        {
          id = ("%s::%s"):format(test_file, "TEST_CASE"),
          name = "TEST_CASE",
          path = test_file,
          range = { 2, 0, 6, 1 },
          type = "namespace",
        },
        {
          {
            id = ("%s::%s::%s"):format(test_file, "TEST_CASE", "First"),
            name = "First",
            path = test_file,
            range = { 4, 0, 4, 48 },
            type = "test",
          },
        },
      },
      {
        {
          id = ("%s::%s"):format(test_file, "Second"),
          name = "Second",
          path = test_file,
          range = { 8, 0, 11, 1 },
          type = "test",
        },
      },
    }

    -- NOTE: assert.are.same() crops the output when table is too deep.
    -- Splitting the assertions for increased readability in case of failure.
    assert.are.same(expected_positions[1], actual_positions[1])
    assert.are.same(expected_positions[2][1], actual_positions[2][1])
    assert.are.same(expected_positions[2][2][1], actual_positions[2][2][1])
    assert.are.same(expected_positions[3][1], actual_positions[3][1])
  end)

  it("discovers TEST_CASE_METHOD macro", function()
    local test_file = vim.loop.cwd() .. "/tests/unit/data/catch2/TEST_CASE_METHOD_test.cpp"
    local actual_positions = catch2.parse_positions(test_file):to_list()
    local expected_positions = {
      {
        id = test_file,
        name = "TEST_CASE_METHOD_test.cpp",
        path = test_file,
        range = { 0, 0, 10, 0 },
        type = "file",
      },
      {
        {
          id = ("%s::%s"):format(test_file, "First"),
          name = "First",
          path = test_file,
          range = { 4, 0, 4, 64 },
          type = "test",
        },
      },
      {
        {
          id = ("%s::%s"):format(test_file, "Second"),
          name = "Second",
          path = test_file,
          range = { 6, 0, 9, 1 },
          type = "test",
        },
      },
    }

    assert.are.same(expected_positions[1], actual_positions[1])
    assert.are.same(expected_positions[2][1], actual_positions[2][1])
    assert.are.same(expected_positions[3][1], actual_positions[3][1])
  end)

  it("discovers TEST_CASE_METHOD macro inside a namespace without duplication", function()
    local test_file = vim.loop.cwd() .. "/tests/unit/data/catch2/TEST_CASE_METHOD_NAMESPACE_test.cpp"
    local actual_positions = catch2.parse_positions(test_file):to_list()
    local expected_positions = {
      {
        id = test_file,
        name = "TEST_CASE_METHOD_NAMESPACE_test.cpp",
        path = test_file,
        range = { 0, 0, 15, 0 },
        type = "file",
      },
      {
        {
          id = ("%s::%s"):format(test_file, "MyTests"),
          name = "MyTests",
          path = test_file,
          range = { 4, 0, 13, 1 },
          type = "namespace",
        },
        {
          {
            id = ("%s::%s::%s"):format(test_file, "MyTests", "First"),
            name = "First",
            path = test_file,
            range = { 6, 0, 6, 64 },
            type = "test",
          },
        },
        {
          {
            id = ("%s::%s::%s"):format(test_file, "MyTests", "Second"),
            name = "Second",
            path = test_file,
            range = { 8, 0, 11, 1 },
            type = "test",
          },
        },
      },
    }

    -- Ensure exactly the right number of top-level entries (file + 1 namespace, no duplicates)
    assert.are.same(2, #actual_positions)
    assert.are.same(expected_positions[1], actual_positions[1])
    assert.are.same(expected_positions[2][1], actual_positions[2][1])
    assert.are.same(expected_positions[2][2][1], actual_positions[2][2][1])
    assert.are.same(expected_positions[2][3][1], actual_positions[2][3][1])
  end)

  it("discovers SECTION blocks nested in TEST_CASE_METHOD macro", function()
    local test_file = vim.loop.cwd() .. "/tests/unit/data/catch2/TEST_CASE_METHOD_SECTION_test.cpp"
    local actual_positions = catch2.parse_positions(test_file):to_list()
    local expected_positions = {
      {
        id = test_file,
        name = "TEST_CASE_METHOD_SECTION_test.cpp",
        path = test_file,
        range = { 0, 0, 13, 0 },
        type = "file",
      },
      {
        {
          id = ("%s::%s"):format(test_file, "With sections"),
          name = "With sections",
          path = test_file,
          range = { 4, 0, 11, 1 },
          type = "test",
        },
        {
          {
            id = ("%s::%s::%s"):format(test_file, "With sections", "First section"),
            name = "First section",
            path = test_file,
            range = { 5, 2, 7, 3 },
            type = "test",
          },
        },
        {
          {
            id = ("%s::%s::%s"):format(test_file, "With sections", "Second section"),
            name = "Second section",
            path = test_file,
            range = { 8, 2, 10, 3 },
            type = "test",
          },
        },
      },
    }

    assert.are.same(expected_positions[1], actual_positions[1])
    assert.are.same(expected_positions[2][1], actual_positions[2][1])
    assert.are.same(expected_positions[2][2][1], actual_positions[2][2][1])
    assert.are.same(expected_positions[2][3][1], actual_positions[2][3][1])
  end)

  it("discovers SCENARIO macro", function()
    local test_file = vim.loop.cwd() .. "/tests/unit/data/catch2/SCENARIO_test.cpp"
    local actual_positions = catch2.parse_positions(test_file):to_list()
    local expected_positions = {
      {
        id = test_file,
        name = "SCENARIO_test.cpp",
        path = test_file,
        range = { 0, 0, 28, 0 },
        type = "file",
      },
      {
        {
          id = ("%s::%s"):format(test_file, "Scenario: First"),
          name = "Scenario: First",
          path = test_file,
          range = { 2, 0, 12, 1 },
          type = "test",
        },
      },
      {
        {
          id = ("%s::%s"):format(test_file, "Scenario: Second"),
          name = "Scenario: Second",
          path = test_file,
          range = { 14, 0, 27, 1 },
          type = "test",
        },
      },
    }

    assert.are.same(expected_positions[1], actual_positions[1])
    assert.are.same(expected_positions[2][1], actual_positions[2][1])
    assert.are.same(expected_positions[3][1], actual_positions[3][1])
  end)

  it("discovers nested BDD sections in SCENARIO macro", function()
    local test_file = vim.loop.cwd() .. "/tests/unit/data/catch2/SCENARIO_test.cpp"
    local actual_positions = catch2.parse_positions(test_file):to_list()

    -- "Scenario: First" -> "Given: ..." -> "When: ..." -> "Then: ..."
    local scenario_first    = actual_positions[2][1]
    local given_first       = actual_positions[2][2][1]
    local when_first        = actual_positions[2][2][2][1]
    local then_first        = actual_positions[2][2][2][2][1]

    assert.are.same("Scenario: First", scenario_first.name)
    assert.are.same({ 2, 0, 12, 1 },   scenario_first.range)

    assert.are.same("Given: A counter starting at zero", given_first.name)
    assert.are.same({ 3, 2, 11, 3 },   given_first.range)

    assert.are.same("When: Incremented by 1", when_first.name)
    assert.are.same({ 6, 4, 10, 5 },   when_first.range)

    assert.are.same("Then: The value should equal 1", then_first.name)
    assert.are.same({ 9, 6, 9, 59 },   then_first.range)

    -- "Scenario: Second" -> "Given: ..." -> "When: ..." -> "Then: ..."
    local scenario_second   = actual_positions[3][1]
    local given_second      = actual_positions[3][2][1]
    local when_second       = actual_positions[3][2][2][1]
    local then_second       = actual_positions[3][2][2][2][1]

    assert.are.same("Scenario: Second", scenario_second.name)
    assert.are.same({ 14, 0, 27, 1 },  scenario_second.range)

    assert.are.same("Given: A counter starting at zero", given_second.name)
    assert.are.same({ 15, 2, 26, 3 },  given_second.range)

    assert.are.same("When: Incremented by 2", when_second.name)
    assert.are.same({ 18, 4, 25, 5 },  when_second.range)

    assert.are.same("Then: The value should equal 2", then_second.name)
    assert.are.same({ 21, 6, 24, 7 },  then_second.range)
  end)
end)

describe("catch2.parse_errors", function()
  it("parses diagnostics correctly", function()
    -- NOTE: Partial catch2 output (only the relevant portions are included
    local output = [[
Filters: "Second"
Randomness seeded to: 2250342149

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
catch2_test is a Catch2 v3.3.0 host application.
Run with -? for options

-------------------------------------------------------------------------------
Second
-------------------------------------------------------------------------------
/path/to/TEST_CASE_test.cpp:5
...............................................................................

/path/to/TEST_CASE_test.cpp:6: FAILED:
  CHECK( false )

/path/to/TEST_CASE_test.cpp:7: FAILED:
  REQUIRE( false )

===============================================================================
test cases: 1 | 1 failed
assertions: 2 | 2 failed
]]

    local actual_errors = catch2.parse_errors(output)
    local expected_errors = {
      {
        line = 6,
        message = "  CHECK( false )",
      },
      {
        line = 7,
        message = "  REQUIRE( false )",
      },
    }

    assert.are.same(expected_errors, actual_errors)
  end)
end)
