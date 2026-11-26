# Required (after the gem itself) by `gem-types collect --sources prototype`,
# as one more `rbs prototype runtime -r`: loads every constant registered
# with `autoload` under the namespaces in GEM_TYPES_EAGER_NS (comma list),
# recursively, so the prototype sees classes the gem loads lazily. Then,
# for gems that load parts on demand without autoload (plugin hosts such
# as CodeRay::Scanners), requires the remaining files of the library
# directories in GEM_TYPES_EAGER_LIB (colon list) that sit in a directory
# the gem already loaded a file from (lib/coderay/** once lib/coderay/x.rb
# is loaded; never unrelated top-level files).
# A constant or file that fails to load is reported and skipped.
module GemTypesEagerLoad
  NAME = Module.instance_method(:name)

  def self.run(names)
    seen = {}
    queue = names.filter_map do |n|
      Object.const_get(n)
    rescue NameError, LoadError => e
      warn "eager_load: #{n}: #{e.class}: #{e.message}"
      nil
    end
    prefixes = names.map { |n| "#{n}::" }
    until queue.empty?
      mod = queue.shift
      next unless mod.is_a?(Module) && !seen[mod]

      seen[mod] = true
      name = NAME.bind_call(mod)
      next unless name && (names.include?(name) || prefixes.any? { |p| name.start_with?(p) })

      mod.constants(false).each do |c|
        value = begin
          mod.autoload?(c) ? mod.const_get(c, false) : (mod.const_get(c, false) if mod.const_defined?(c, false))
        rescue Exception => e # rubocop:disable Lint/RescueException
          raise if e.is_a?(Interrupt) || e.is_a?(SystemExit)

          warn "eager_load: #{name}::#{c}: #{e.class}: #{e.message.lines.first&.chomp}"
          nil
        end
        queue << value if value.is_a?(Module)
      end
    end
  end

  def self.require_rest(libs)
    loaded = $LOADED_FEATURES.map { |f| File.expand_path(f) }
    libs.each do |lib|
      lib = File.join(File.expand_path(lib), "")
      roots = loaded.filter_map do |f|
        next unless f.start_with?(lib)

        top = f.delete_prefix(lib).split("/")
        File.join(lib, top.first, "") if top.size > 1
      end.uniq
      roots.flat_map { |r| Dir[File.join(r, "**", "*.rb")] }.sort.each do |file|
        next if loaded.include?(file)

        begin
          require file
        rescue Exception => e # rubocop:disable Lint/RescueException
          raise if e.is_a?(Interrupt)

          warn "eager_load: #{file}: #{e.class}: #{e.message.lines.first&.chomp}"
        end
      end
    end
  end
end
names = ENV.fetch("GEM_TYPES_EAGER_NS", "").split(",").map(&:strip).reject(&:empty?)
GemTypesEagerLoad.run(names)
GemTypesEagerLoad.require_rest(ENV.fetch("GEM_TYPES_EAGER_LIB", "").split(":").reject(&:empty?))
GemTypesEagerLoad.run(names)
