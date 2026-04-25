# neotest-ctest Copilot Instructions

## Project Overview

A [neotest](https://github.com/nvim-neotest/neotest) adapter for C/C++ using CTest as a test runner. Written in Lua for Neovim. Supports GoogleTest, Catch2, doctest, and CppUTest frameworks.

## Build, Test, and Lint Commands

```bash
# One-time setup (installs deps and Tree-sitter parsers)
make setup

# Run all tests
make test

# Run unit tests only (Linux only — tree-sitter position parsing differs on Windows/macOS)
make unit

# Build integration test fixtures, then run integration tests
make integration

# Run a single unit test file
nvim --headless -u tests/unit/minimal_init.lua \
  -c "PlenaryBustedFile tests/unit/gtest_spec.lua" -c q

# Lint (style check via stylua)
stylua --check lua/ tests/
```

**stylua config** (`.stylua.toml`): 100-column width, 2-space indent, Unix line endings, double quotes, spaces (not tabs).

Logs for debugging test failures are written to `.sandbox/state/nvim/neotest.log` and `.sandbox/state/nvim/nio.log`.

## Architecture

```
lua/neotest-ctest/
  init.lua          ← neotest adapter entry point (root, filter_dir, is_test_file,
                        discover_positions, build_spec, results)
  config.lua        ← adapter config with defaults; accessed as a module-level proxy
  ctest.lua         ← CTest wrapper: locates CTestTestfile.cmake, runs ctest,
                        parses JUnit XML output
  framework/
    init.lua        ← framework auto-detection via Tree-sitter include queries
    gtest.lua       ← GoogleTest: position parser + error parser
    catch2.lua      ← Catch2: position parser + error parser (supports SECTION nodes)
    doctest.lua     ← doctest: position parser + error parser
    cpputest.lua    ← CppUTest: position parser + error parser
```

### Data flow

1. **`discover_positions`** → `framework.detect(path)` reads the file and runs each framework's `include_query` via Tree-sitter to identify the framework, then calls `framework.parse_positions(path)`.
2. **`build_spec`** → creates a `ctest` session, calls `ctest:testcases()` (runs `ctest --show-only=json-v1`) to get the CTest index, maps neotest tree nodes to CTest test indices, and builds the CTest command using the `-I 0,0,0,<indices>` filter.
3. **`results`** → parses the JUnit XML file produced by CTest (`--output-junit`) and maps results back to neotest node IDs via `framework.parse_errors()`.

### Special cases

- **Catch2 SECTION nodes**: SECTION/GIVEN/WHEN/THEN blocks are parsed as nested `test` nodes with a `section_filter` field. When running a single SECTION, the test executable is invoked directly (`--reporter junit --out <path>`) with `-c <section_name>` filters instead of going through CTest.
- **DAP debugging**: When `args.strategy == "dap"`, `build_spec` returns a `strategy` table that launches the test executable directly under the configured `dap_adapter`.
- **Multi-config projects**: `ctest:new()` scans up to depth 3 for `CTestTestfile.cmake` to support `<root>/build/<config>/` layouts.

## Key Conventions

### Test files

- Unit tests live in `tests/unit/` and are named `*_spec.lua`.
- Integration tests live in `tests/integration/`; disabled tests use the `.luax` extension instead of `.lua`.
- Test data (fixture C++ files) lives in `tests/unit/data/<framework>/`.
- Always use `local it = require("nio").tests.it` for async-capable tests — do **not** use plenary's bare `it`.
- When asserting deep tables, split assertions per level (`assert.are.same(expected[2][1], actual[2][1])`) because `assert.are.same` truncates output for deep tables.

### Framework modules

Each framework module must expose:
- `lang` — Tree-sitter language string (e.g. `"cpp"`)
- `include_query` — Tree-sitter query string used for framework detection (matches the framework's `#include`)
- `tests_query` — Tree-sitter query string used to discover test positions
- `parse_positions(path)` — returns a neotest position tree
- `parse_errors(output)` — returns `{ { line = number, message = string }, ... }`

### Config

`config.lua` uses a metatable proxy so consumers `require("neotest-ctest.config").some_key` work without calling a getter. Use `config.setup(user_config)` to merge with `vim.tbl_deep_extend("force", default_config, user_config)`. Use `config.get()` and `config.get_default()` in tests.

### neotest error line offsets

When returning errors from `results`, subtract 1 from parsed line numbers (`error.line = error.line - 1`) because neotest adds 1 internally.

### XDG sandbox

Tests redirect all XDG dirs into `.sandbox/` (set by the Makefile) to avoid polluting the developer's real Neovim config.
