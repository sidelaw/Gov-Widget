# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name        = "discourse_theme"
  spec.version     = "0.0.1"
  spec.authors     = ["Discourse"]
  spec.email       = ["team@discourse.org"]

  spec.summary     = "Compound Governance Widget - Discourse Theme Component"
  spec.description = "A Discourse theme component for compound governance widget"
  spec.homepage    = "https://github.com/discourse/compound-governance-widget"
  spec.license     = "MIT"

  spec.files = Dir[
    "about.json",
    "assets/**/*",
    "common/**/*",
    "javascripts/**/*",
    "locales/**/*",
    "settings.yml",
    "stylesheets/**/*"
  ].select { |f| File.file?(f) }

  spec.required_ruby_version = ">= 2.7.0"
end

