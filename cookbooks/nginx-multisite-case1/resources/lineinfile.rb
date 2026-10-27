provides :lineinfile

property :file_path, String, name_property: true
property :line, String, required: true
property :match, String
property :backup, [true, false], default: true

action :create do
  file_path = new_resource.file_path
  line = new_resource.line
  match_pattern = new_resource.match
  
  ruby_block "update_line_in_#{file_path}" do
    block do
      if ::File.exist?(file_path)
        content = ::File.read(file_path)
        
        if match_pattern
          if content.match(/#{match_pattern}/)
            new_content = content.gsub(/#{match_pattern}.*$/, line)
          else
            new_content = content + "\n" + line
          end
        else
          unless content.include?(line)
            new_content = content + "\n" + line
          else
            new_content = content
          end
        end
        
        if new_content != content
          if new_resource.backup
            ::File.write("#{file_path}.backup.#{Time.now.to_i}", content)
          end
          ::File.write(file_path, new_content)
        end
      else
        ::File.write(file_path, line)
      end
    end
  end
end