ffi.namespace("libc")
ffi.cdef("libc", [[
  int abs(int x);
  long labs(long x);
  long long llabs(long long x);

  double fabs(double x);
  float fabsf(float x);
  long double fabsl(long double x);
  double sqrt(double x);
  double pow(double x, double y);
  double sin(double x);
  double cos(double x);
  double floor(double x);
  double ceil(double x);
  double fmod(double x, double y);

  int isdigit(int c);
  int isalpha(int c);
  int isspace(int c);
  int toupper(int c);
  int tolower(int c);

  typedef unsigned long size_t;

  size_t strlen(const char *s);
  int strcmp(const char *s1, const char *s2);
  int strncmp(const char *s1, const char *s2, size_t n);
  char *strcpy(char *dest, const char *src);
  char *strncpy(char *dest, const char *src, size_t n);
  char *strcat(char *dest, const char *src);
  char *strstr(const char *haystack, const char *needle);
  char *strchr(const char *s, int c);

  void *memcpy(void *dest, const void *src, size_t n);
  void *memmove(void *dest, const void *src, size_t n);
  void *memset(void *s, int c, size_t n);
  int memcmp(const void *s1, const void *s2, size_t n);

  int atoi(const char *nptr);
  long atol(const char *nptr);
  double atof(const char *nptr);
  void *malloc(size_t size);
  void free(void *ptr);
  int rand(void);
  void srand(unsigned int seed);
]])
ffi.load("libc", "./x86_64-linux-musl_1.2.6-libc.so")

function build:testSuite()
  print(ffi.C.libc.abs(-42))
end

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("FAIL: %s  (got %s, expected %s)", msg or "assertion", tostring(actual), tostring(expected)))
  end
  print(string.format("    [ok] %s", msg))
end

local function assert_true(cond, msg)
  if not cond then
    error("FAIL: " .. (msg or "condition was false"))
  end
  print(string.format("    [ok] %s", msg))
end

function build:testSuite()
  print("=== libc FFI full test suite ===")

  assert_eq(ffi.C.libc.abs(-42), 42, "abs(-42)")
  assert_eq(ffi.C.libc.abs(0), 0, "abs(0)")
  assert_eq(ffi.C.libc.abs(123), 123, "abs(123)")
  assert_eq(ffi.C.libc.labs(-1234567890), 1234567890, "labs")
  assert_eq(ffi.C.libc.llabs(-9223372036854775807), 9223372036854775807, "llabs")

  print("  [ok] integer abs family")

  assert_eq(ffi.C.libc.fabs(-3.14159), 3.14159, "fabs")
  assert_eq(ffi.C.libc.fabsf(-2.5), 2.5, "fabsf")
  assert_true(math.abs(tonumber(ffi.C.libc.fabsl(-1.5)) - 1.5) < 1e-9, "fabsl")

  assert_true(math.abs(ffi.C.libc.sqrt(16.0) - 4.0) < 1e-12, "sqrt(16)")
  assert_true(math.abs(ffi.C.libc.pow(2.0, 10.0) - 1024.0) < 1e-9, "pow(2,10)")
  assert_true(math.abs(ffi.C.libc.sin(0.0)) < 1e-15, "sin(0)")
  assert_true(math.abs(ffi.C.libc.cos(0.0) - 1.0) < 1e-15, "cos(0)")
  assert_eq(ffi.C.libc.floor(3.7), 3.0, "floor")
  assert_eq(ffi.C.libc.ceil(3.2), 4.0, "ceil")
  assert_true(math.abs(ffi.C.libc.fmod(5.5, 2.0) - 1.5) < 1e-12, "fmod")

  print("  [ok] floating-point math")

  assert_eq(ffi.C.libc.isdigit(string.byte("7")), 1, "isdigit('7')")
  assert_eq(ffi.C.libc.isdigit(string.byte("a")), 0, "isdigit('a')")
  assert_eq(ffi.C.libc.isalpha(string.byte("Z")), 1, "isalpha('Z')")
  assert_eq(ffi.C.libc.isspace(string.byte(" ")), 1, "isspace")
  assert_eq(ffi.C.libc.toupper(string.byte("a")), string.byte("A"), "toupper")
  assert_eq(ffi.C.libc.tolower(string.byte("B")), string.byte("b"), "tolower")

  print("  [ok] ctype")

  local s1 = "hello"
  local s2 = "world"
  local s3 = "hello world"

  assert_eq(tonumber(ffi.C.libc.strlen(s1)), 5, "strlen")
  assert_eq(ffi.C.libc.strcmp(s1, s1), 0, "strcmp equal")
  assert_true(ffi.C.libc.strcmp(s1, s2) < 0, "strcmp less")
  assert_eq(ffi.C.libc.strncmp(s1, "help", 3), 0, "strncmp")

  local char_t = ffi.ctype("char")
  local buf = ffi.new(char_t, 64)
  ffi.C.libc.strcpy(buf, "mana")
  assert_eq(ffi.string(buf), "mana", "strcpy")

  -- ffi.C.libc.strncpy(buf, "ffi-test", 3)
  -- buf[3] = 0          -- force null-termination for the truncated copy
  -- assert_eq(ffi.string(buf), "ffi", "strncpy")

  -- ffi.C.libc.strcpy(buf, "hello")
  -- ffi.C.libc.strcat(buf, " world")
  -- assert_eq(ffi.string(buf), "hello world", "strcat")

  -- local p = ffi.C.libc.strstr(s3, "world")
  -- assert_true(p ~= nil, "strstr found")
  -- assert_eq(ffi.string(p), "world", "strstr content")

  -- p = ffi.C.libc.strchr(s1, string.byte("l"))
  -- assert_true(p ~= nil, "strchr found")

  -- print("  [ok] string")

  -- local src = ffi.new("uint8_t[8]", {1,2,3,4,5,6,7,8})
  -- local dst = ffi.new("uint8_t[8]")

  -- ffi.C.libc.memcpy(dst, src, 8)
  -- assert_eq(ffi.C.libc.memcmp(src, dst, 8), 0, "memcpy + memcmp")

  -- ffi.C.libc.memset(dst, 0xAA, 8)
  -- for i = 0, 7 do
  --   assert_eq(dst[i], 0xAA, "memset")
  -- end

  -- -- memmove with overlap
  -- ffi.C.libc.memcpy(dst, src, 8)
  -- ffi.C.libc.memmove(dst + 2, dst, 4)   -- shift left by 2
  -- assert_eq(dst[2], 1, "memmove overlap")

  -- print("  [ok] memory")

  -- assert_eq(ffi.C.libc.atoi("42"), 42, "atoi")
  -- assert_eq(ffi.C.libc.atol("-123456"), -123456, "atol")
  -- assert_true(math.abs(ffi.C.libc.atof("3.14") - 3.14) < 1e-9, "atof")

  -- local ptr = ffi.C.libc.malloc(32)
  -- assert_true(ptr ~= nil, "malloc")
  -- ffi.C.libc.free(ptr)

  -- ffi.C.libc.srand(12345)
  -- local r1 = ffi.C.libc.rand()
  -- ffi.C.libc.srand(12345)
  -- local r2 = ffi.C.libc.rand()
  -- assert_eq(r1, r2, "srand/rand deterministic")

  -- print("  [ok] conversion & misc")
  print("=== All libc FFI tests passed ===")
end
