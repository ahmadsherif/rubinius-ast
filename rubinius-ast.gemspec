# coding: utf-8
require 'rubinius/ast/version'

Gem::Specification.new do |spec|
  spec.name          = "rubinius-ast"
  spec.version       = Rubinius::Ast::VERSION
  spec.authors       = ["Brian Shirai"]
  spec.email         = ["brixen@gmail.com"]
  spec.description   = %q{An Abstract Syntax Tree for Ruby.}
  spec.summary       = %q{An Abstract Syntax Tree for Ruby.}
  spec.homepage      = "https://github.com/rubinius/rubinius-ast"
  spec.license       = "BSD"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "redcard", "~> 1.0"

  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rake", "~> 10.0"
end
