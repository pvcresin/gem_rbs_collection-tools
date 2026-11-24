# Loaded with -r by `gem-types collect --sources rbs_trace`. Runs rbs-trace
# (https://github.com/sinsoku/rbs-trace) for the whole process and saves the
# RBS it inferred under RBS_TRACE_OUT/<pid>/. Only files under
# RBS_TRACE_PATHS (colon-separated directories) are traced.
# RUBYOPT also reaches the `bundle` command itself; only hook real programs.
return if %w[bundle bundler].include?(File.basename($PROGRAM_NAME))
require "rbs/trace"
paths = ENV.fetch("RBS_TRACE_PATHS").split(":").flat_map { |d| Dir.glob(File.join(File.expand_path(d), "**/*.rb")) }
$__gem_types_rbs_trace = RBS::Trace.new(paths: paths)
$__gem_types_rbs_trace.enable
at_exit do
  $__gem_types_rbs_trace.disable
  begin
    $__gem_types_rbs_trace.save_files(out_dir: File.join(ENV.fetch("RBS_TRACE_OUT"), Process.pid.to_s))
  rescue StandardError => e
    warn "rbs-trace: could not save (#{e.class}: #{e.message})"
  end
end
