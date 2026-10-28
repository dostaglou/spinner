# frozen_string_literal: true

require_relative "lib/spinner/version"

Gem::Specification.new do |spec|
  spec.name = "spinner"
  spec.version = Spinner::VERSION
  spec.authors = ["Dillon Wyatt"]
  spec.email = ["dostaglou@gmail.com"]

  spec.summary = "A Spinel-compatible HTTP application server"
  spec.description = "Spinner compiles with a Spinel application to serve HTTP/1.1 traffic."
  spec.homepage = "https://github.com/dostaglou/spinner"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # Include working-tree library files so pre-port contract tests exercise the
  # exact implementation under review, including files not yet committed.
  spec.files = Dir.chdir(__dir__) do
    Dir.glob("{lib,sig}/**/*", File::FNM_DOTMATCH).select { |path| File.file?(path) } +
      %w[README.md LICENSE.txt CHANGELOG.md]
  end
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
