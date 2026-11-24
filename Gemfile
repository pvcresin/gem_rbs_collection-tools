# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 3.3"

gem "prism", "~> 1.4"
gem "rbs", "~> 4.2"
gem "typeprof", "~> 0.33"
gem "tyda"

# YARD docs -> RBS (documented contract)
gem "sord", "~> 7.1"
gem "yard", "~> 0.9"

# Type-checks the gem's own code against signatures
gem "steep", "~> 2.1"

# Loaded into the gem's own test environment (see prepare_gem.sh), listed
# here so versions are pinned in one place.
gem "lumitrace", "~> 0.7"
gem "rbs-trace", "~> 0.7"

group :test do
  gem "minitest"
end
