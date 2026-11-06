provides :ada_ada

property :file_path, String, name_property: true
property :line, String, required: true
property :match, String, required: true

action :create do
  file_path = new_resource.file_path
  line = new_resource.line
  match_pattern = new_resource.match

  ruby_block "update_line_in_#{file_path}" do
    block do
      raise "ada_ada: file not found: #{file_path}" unless ::File.exist?(file_path)

      content = ::File.read(file_path)
      regex = /#{match_pattern}/

      new_content = content.split("\n").map { |l| l.match?(regex) ? line : l }.join("\n")

      if new_content != content
        ::File.write(file_path, new_content)
      end
    end
  end
end
