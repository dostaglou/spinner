# frozen_string_literal: true

require_relative "test_helper"

class ReactorHandoffTest < Minitest::Test
  FIXTURE = File.join(__dir__, "fixtures", "reactor_handoff.rb")

  def test_real_reactor_handoff_under_cruby
    output = run_checked(RbConfig.ruby, "-I", File.join(SpinnerTest::ROOT, "lib"), FIXTURE)
    assert_includes(output, "SPINNER_REACTOR_HANDOFF_OK")
  end

  def test_real_reactor_handoff_under_spinel_from_packaged_gem
    Dir.mktmpdir("spinner-handoff-") do |directory|
      gem_file = File.join(directory, "spinel-spinner.gem")
      run_checked("gem", "build", "spinel-spinner.gemspec", "--output", gem_file,
                  chdir: SpinnerTest::ROOT)
      package = File.join(directory, "package")
      Gem::Package.new(gem_file).extract_files(package)
      binary = File.join(directory, "reactor_handoff")
      run_checked("spinel", FIXTURE, "--require-gate", "-I", File.join(package, "lib"), "-o", binary,
                  chdir: directory)
      output = run_checked(binary, chdir: directory)
      assert_includes(output, "SPINNER_REACTOR_HANDOFF_OK")
    end
  end

  private

  def run_checked(*command, chdir: SpinnerTest::ROOT)
    output = ""
    status = nil
    Open3.popen2e(*command, chdir: chdir, pgroup: true) do |stdin, pipe, child|
      stdin.close
      begin
        Timeout.timeout(60) do
          output = pipe.read
          status = child.value
        end
      ensure
        unless child.join(0)
          Process.kill("KILL", -child.pid)
          child.join
        end
      end
    end
    assert(status.success?, "#{command.first} failed (#{status.inspect}):\n#{output}")
    output
  end
end
