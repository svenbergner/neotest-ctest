#include <catch2/catch_test_macros.hpp>

class Fixture {};

TEST_CASE_METHOD(Fixture, "With sections", "[fixture]") {
  SECTION("First section") {
    REQUIRE(true);
  }
  SECTION("Second section") {
    REQUIRE(true);
  }
}

