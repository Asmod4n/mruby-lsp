assert('Platform::OS is a known symbol') do
  assert_kind_of(Symbol, Platform::OS)
  assert_include(%i[linux macos windows unknown], Platform::OS)
end

assert('Platform::Toolchain is a known symbol') do
  assert_kind_of(Symbol, Platform::Toolchain)
  assert_include(%i[gcc clang msvc unknown], Platform::Toolchain)
end
