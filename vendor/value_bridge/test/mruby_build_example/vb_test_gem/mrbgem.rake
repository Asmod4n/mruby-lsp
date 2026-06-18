MRuby::Gem::Specification.new("mruby-vb-test") do |spec|
  spec.license = "MIT"; spec.authors = ["test"]
  spec.add_dependency "mruby-value-bridge"   # pulls its exported include/ + converters
end
