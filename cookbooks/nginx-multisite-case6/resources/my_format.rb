resource_name :my_format
provides :my_format

property :file_path, String, name_property: true
property :entry, String, required: true
property :value, String, required: true

default_action :set

action :set do
  # CompanyApp settings files use a proprietary format: one '!key=value'
  # entry per line. Comment lines (starting with '#') and unparseable lines
  # must be preserved as-is.
  lines = if ::File.exist?(new_resource.file_path)
            ::File.readlines(new_resource.file_path).map(&:chomp)
          else
            []
          end

  lines = lines.reject do |line|
    line.start_with?('!') && !line[1..].partition('=').last.empty? && line[1..].partition('=').first.strip == new_resource.entry
  end
  lines << "!#{new_resource.entry}=#{new_resource.value}"

  ::File.open(new_resource.file_path, 'w') { |f| f.puts(lines) }
end

action :remove do
  return unless ::File.exist?(new_resource.file_path)

  lines = ::File.readlines(new_resource.file_path).map(&:chomp)
  lines = lines.reject do |line|
    line.start_with?('!') && !line[1..].partition('=').last.empty? && line[1..].partition('=').first.strip == new_resource.entry
  end

  ::File.open(new_resource.file_path, 'w') { |f| f.puts(lines) }
end
