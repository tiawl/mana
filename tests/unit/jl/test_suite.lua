expected = {
  testSuite = {
    cases = {
      {
        expectations = {
          allowEmptyCollections = true,
          mustPreserveNull = true,
          notes = {
            "Zero is a valid value and must not be treated as missing.",
            "The large integer is within JavaScript's safe integer range."
          }
        },
        id = "case-001",
        input = {
          booleanFalse = false,
          booleanTrue = true,
          emptyArray = {
          },
          emptyObject = JSON_EMPTY_OBJECT,
          emptyString = "",
          explicitNull = JSON_NULL,
          largeInteger = 9007199254740991,
          negativeInteger = -9007199254740991,
          negativeZero = 0,
          smallestPracticalDecimal = 1e-12,
          whitespaceOnly = [[ 	
 ]],
          zero = 0
        },
        kind = "boundary-values"
      },
      {
        expectedPathChecks = {
          {
            expected = true,
            path = "user.profile.preferences.notifications.email.enabled"
          },
          {
            expected = {
            },
            path = "user.profile.preferences.notifications.push.deviceIds"
          },
          {
            expected = JSON_NULL,
            path = "user.profile.preferences.layout.panels[1].width"
          }
        },
        id = "case-002",
        input = {
          user = {
            id = "u-💠-0042",
            profile = {
              aliases = {
                "Z",
                "zoe",
                "",
                JSON_NULL
              },
              displayName = "Zoë 李",
              preferences = {
                layout = {
                  density = JSON_NULL,
                  panels = {
                    {
                      name = "activity",
                      visible = true,
                      width = 0
                    },
                    {
                      name = "details",
                      visible = false,
                      width = JSON_NULL
                    }
                  },
                  theme = "system"
                },
                notifications = {
                  email = {
                    enabled = true,
                    quietHours = {
                      days = {
                        "Mon",
                        "Tue",
                        "Wed",
                        "Thu",
                        "Fri"
                      },
                      ["end"] = "07:00",
                      start = "22:00"
                    }
                  },
                  push = {
                    deviceIds = {
                    },
                    enabled = false
                  }
                }
              }
            }
          }
        },
        kind = "deeply-nested"
      },
      {
        expectations = {
          parseAsDataOnly = true,
          preserveEscapedCharacters = true,
          preserveUnicode = true
        },
        id = "case-003",
        input = {
          backslashes = "C:\\temp\\folder\\file.txt",
          combiningCharacters = "é",
          controlCharacterEscaped = "\0",
          htmlLike = "<script>alert(\"not executable\")</script>",
          jsonLikeText = "{\"looks\":\"like JSON, but is a string\"}",
          lineBreaks = "first line\
second line\13\
third line",
          quotes = "She said, \"hello\".",
          unicode = "Καλημέρα — こんにちは — مرحبًا — 🧪",
          zeroWidthCharacter = "A​B"
        },
        kind = "strings-and-escaping"
      },
      {
        expectations = {
          arrayLength = 11,
          doNotCoerceTypes = true,
          preserveElementOrder = true
        },
        id = "case-004",
        input = {
          JSON_NULL,
          true,
          false,
          0,
          -1,
          3.14159,
          "",
          "text",
          {
          },
          JSON_EMPTY_OBJECT,
          {
            nested = {
              {
                value = JSON_NULL
              },
              {
                value = {
                  "leaf",
                  {
                    deeper = {
                      level = 4
                    }
                  }
                }
              }
            }
          }
        },
        kind = "mixed-array"
      },
      {
        expectedDistinctions = {
          emptyArrayIsDifferentFromMissing = true,
          falseIsDifferentFromZero = true,
          missingIsDifferentFromNull = true,
          nullIsDifferentFromEmptyString = true
        },
        id = "case-005",
        input = {
          error = {
            code = "E_TEST",
            details = JSON_NULL,
            message = ""
          },
          presentAndEmpty = "",
          presentAndEmptyArray = {
          },
          presentAndEmptyObject = JSON_EMPTY_OBJECT,
          presentAndFalse = false,
          presentAndNull = JSON_NULL,
          presentAndZero = 0,
          retryCount = 0,
          status = "unknown"
        },
        kind = "optional-and-state"
      },
      {
        id = "case-006",
        input = {
          lookup = {
            key = "alpha",
            revision = 1
          },
          records = {
            {
              key = "alpha",
              revision = 1,
              value = "first"
            },
            {
              key = "alpha",
              revision = 1,
              value = "duplicate"
            },
            {
              key = "alpha",
              revision = 2,
              value = JSON_NULL
            },
            {
              key = "",
              revision = 0,
              value = {
              }
            }
          }
        },
        kind = "records-with-duplicates",
        testCases = {
          {
            expectedValue = "first",
            operation = "find-first"
          },
          {
            expectedCount = 2,
            operation = "find-all"
          },
          {
            expectedValue = {
            },
            operation = "match-empty-key"
          }
        }
      }
    },
    globalAssertions = {
      noComments = true,
      noNonFiniteNumbers = true,
      noTrailingCommas = true,
      rootType = "object",
      validJson = true
    },
    metadata = {
      createdAt = "2026-11-22T00:00:00Z",
      description = "Synthetic data for testing parsers, validators, and nested object traversal.",
      isSynthetic = true,
      tags = {
        "json",
        "edge-cases",
        "nested",
        "unicode",
        "nulls"
      }
    },
    name = "nested-edge-cases",
    version = "1.0.0"
  }
}

local function isEmptyJsonObject(t)
    return type(t) == "table"
        and next(t) == nil
        and getmetatable(t) == getmetatable(JSON_EMPTY_OBJECT)
end

-- Source - https://stackoverflow.com/a/32660766
function eql(o1, o2)
    if o1 == o2 then return true end
    local o1Type = type(o1)
    local o2Type = type(o2)
    if o1Type ~= o2Type then return false end
    if o1Type ~= "table" then return false end

    if next(o1) == nil and next(o2) == nil then
        return isEmptyJsonObject(o1) == isEmptyJsonObject(o2)
    end

    local keySet = {}

    for key1, value1 in pairs(o1) do
        local value2 = o2[key1]
        if value2 == nil or not eql(value1, value2) then
            return false
        end
        keySet[key1] = true
    end

    for key2, _ in pairs(o2) do
        if not keySet[key2] then return false end
    end
    return true
end
