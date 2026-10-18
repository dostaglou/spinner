require "spinner"

# Run against packaged code in the same runtime as the deployed server.
def check(condition, message)
  raise message unless condition
end

[63, 64, 65].each do |size|
  storage = Spinner::BodyStorage.new(1024, 64, ".", Spinner::StorageBudget.new(1024))
  begin
    size.times { storage.append("x".b) }
    input = storage.input
    buffer = "old".dup
    check(input.read(2, buffer) == "xx" && buffer == "xx", "output buffer")
    input.rewind
    check(input.read == "x" * size, "body bytes")
    check(input.read(1).nil?, "sized EOF")
    check(input.read == "", "unsized EOF")
    check(input.read(0) == "", "zero length EOF")
    input.rewind
    check(input.read(1).bytesize == 1, "rewind")
    input.close
  ensure
    storage.close
  end
end
input = Spinner::Input.new("a\x00\xff\nsecond\n".b)
check(input.gets == "a\x00\xff\n".b, "binary gets")
input.rewind
lines = []
input.each { |line| lines << line }
check(lines.length == 2, "each lines")
input.close
begin
  input.read
  raise "closed read succeeded"
rescue IOError
end

policy = Spinner::ProxyMetadata.new(["2001:db8::/32", "127.0.0.0/8"])
check(policy.trusted?("2001:db8::1"), "IPv6 trusted network")
check(!policy.trusted?("2001:db9::1"), "IPv6 untrusted network")
check(policy.trusted?("127.2.3.4"), "IPv4 trusted network")
check(!policy.trusted?("128.0.0.1"), "IPv4 untrusted network")

# Probe exclusive binary file operations before socket integration tests.
file = File.open("exclusive-probe", File::RDWR | File::CREAT | File::EXCL, 0600)
begin
  file.binmode
  file.write("a\x00\xff".b)
  file.rewind
  check(file.read == "a\x00\xff".b, "binary file operations")
  begin
    duplicate = File.open("exclusive-probe", File::WRONLY | File::CREAT | File::EXCL, 0600)
    duplicate.close
    raise "exclusive open succeeded twice"
  rescue Errno::EEXIST
  end
ensure
  file.close
  File.unlink("exclusive-probe")
end
# Probe callback marshalling independently of TLS handshakes.
require "ffi"
module SpinnerCallbackProbe
  extend FFI::Library
  ffi_lib FFI::Library::LIBC
  callback :compare, [:pointer, :pointer], :int
  attach_function :qsort, [:pointer, :size_t, :size_t, :compare], :void
end
memory = FFI::MemoryPointer.new(:int, 3)
memory.put_int32(0, 3)
memory.put_int32(4, 1)
memory.put_int32(8, 2)
comparison = proc { |left, right| left.read_int32 <=> right.read_int32 }
SpinnerCallbackProbe.qsort(memory, 3, 4, comparison)
check(memory.get_int32(0) == 1 && memory.get_int32(4) == 2 && memory.get_int32(8) == 3, "FFI callback")
puts "SPINNER_COMPONENTS_OK"
