# Loaded with -r by `gem-types collect --sources lumitrace`. Enables
# Lumitrace (https://github.com/ko1/lumitrace) in "types" mode for files
# under LUMITRACE_ROOT and writes LUMITRACE_OUT/lumitrace-<pid>.json.
# RUBYOPT also reaches the `bundle` command itself; only hook real programs.
return if %w[bundle bundler].include?(File.basename($PROGRAM_NAME))
ENV["LUMITRACE_COLLECT_MODE"] ||= "types"
ENV["LUMITRACE_JSON"] = File.join(ENV.fetch("LUMITRACE_OUT"), "lumitrace-#{Process.pid}.json")
ENV["LUMITRACE_TEXT"] ||= "0"
# Requiring with LUMITRACE_ENABLE=1 enables it from the environment above;
# calling Lumitrace.enable! with no arguments resets those settings.
ENV["LUMITRACE_ENABLE"] = "1"
require "lumitrace"
