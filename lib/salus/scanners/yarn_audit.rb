require 'json'
require 'salus/scanners/node_audit'

# Yarn Audit scanner integration. Flags known malicious or vulnerable
# dependencies in javascript projects that are packaged with yarn.
# https://yarnpkg.com/en/docs/cli/audit

module Salus::Scanners
  class YarnAudit < NodeAudit
    # the command was previously 'yarn audit --json', which had memory allocation issues
    # see https://github.com/yarnpkg/yarn/issues/7404
    AUDIT_COMMAND = 'yarn audit --no-color'.freeze

    def should_run?
      @repository.yarn_lock_present?
    end

    def run
      shell_return = Dir.chdir(@repository.path_to_repo) do
        command = "#{AUDIT_COMMAND} #{scan_deps}"
        shell_return = run_shell(command)

        excpts = fetch_exception_ids.map(&:to_i)
        report_info(:ignored_cves, excpts)
        return report_success if shell_return.success?

        stdout_lines = shell_return.stdout.split("\n")
        table_start_pos = stdout_lines.index { |l| l.start_with?("┌─") && l.end_with?("─┐") }
        table_end_pos = stdout_lines.rindex { |l| l.start_with?("└─") && l.end_with?("─┘") }

        # if no table in output
        if table_start_pos.nil? || table_end_pos.nil?
          report_error(shell_return.stderr, status: shell_return.status)
          report_stderr(shell_return.stderr)
          return report_failure
        end

        table_lines = stdout_lines[table_start_pos..table_end_pos]
        # lines contain 1 or more vuln tables

        vulns = parse_output(table_lines)
        vuln_ids = vulns.map { |v| v['ID'] }
        report_info(:vulnerabilities, vuln_ids.uniq)

        vulns.reject! { |v| excpts.include?(v['ID']) }
        # vulns were all whitelisted
        return report_success if vulns.empty?

        add_line_number(vulns)
        log(format_vulns(vulns))
        report_stdout(vulns.to_json)
        report_failure
      end
    end

    def version
      shell_return = run_shell('yarn audit --version')
      # stdout looks like "1.22.0\n"
      shell_return.stdout&.strip
    end

    def self.supported_languages
      ['javascript']
    end

    private

    def add_line_number(vulns)
      @dep_lines = {}
      parse_yarn_lock
      vulns.each do |vul|
        package = vul['Package']
        patched = vul['Patched in']
        if @dep_lines[package] && (patched.start_with?('>=') || patched == 'No patch available')
          min_version = @dep_lines[package].keys.min
          vul['Line number'] = @dep_lines[package][min_version]
        end
      end
    end

    def parse_yarn_lock
      content = File.read('yarn.lock')
      curr_dep_name = ""
      version_prefix = "  \"version\" \""

      # yarn.lock looks like
      # "abcd@^7.0.0":
      #    "version" "7.0.0"
      # ...
      # where "abcd@^7.0.0" and "version" could be with and without quotes

      content.split("\n").each_with_index do |line, i|
        if line.start_with?("\"") && line.include?("@") # Ex. "yargs@1.2.3":
          at_index = if line.start_with?("\"@") # Ex. "@babel/abc@1.2.3":
                       line[2..].index("@") + 2
                     else
                       line.index("@")
                     end
          curr_dep_name = line[1..at_index - 1]
        elsif line.size.positive? && line[0].match(/\w/) && line.include?("@")
          # like above but no quotes, Ex yargs@1.2.3
          at_index = line.index("@")
          curr_dep_name = line[0..at_index - 1]
        elsif line.start_with?(version_prefix) && line.end_with?("\"") # Ex. "version" "1.2.3"
          version = line[13..-2]
          @dep_lines[curr_dep_name] = {} if @dep_lines[curr_dep_name].nil?
          @dep_lines[curr_dep_name][version] = i + 1
        elsif line.start_with?("  version \"") && line.end_with?("\"") # like above but w/o quotes
          version = line[11..-2]
          @dep_lines[curr_dep_name] = {} if @dep_lines[curr_dep_name].nil?
          @dep_lines[curr_dep_name][version] = i + 1
        end
      end
    end

    def parse_output(lines)
      vulns = Set.new

      i = 0
      while i < lines.size
        if lines[i].start_with?("┌─") && lines[i].end_with?("─┐")
          vuln = {}
        elsif lines[i].start_with? "│ "
          line_split = lines[i].split("│")
          curr_key = line_split[1].strip
          val = line_split[2].strip

          if curr_key != "" && curr_key != 'Path'
            vuln[curr_key] = val
            prev_key = curr_key
          elsif curr_key == 'Path'
            prev_key = curr_key
          elsif prev_key != 'Path'
            vuln[prev_key] += ' ' + val
          end
        elsif lines[i].start_with?("└─") && lines[i].end_with?("─┘")
          vulns.add(vuln)
        end
        i += 1
      end

      vulns = vulns.to_a
      vulns.each { |vln| normalize_vuln(vln) }.sort { |a, b| a['ID'] <=> b['ID'] }
    end

    def scan_deps
      dep_types = @config.fetch('exclude_groups', [])

      return '' if dep_types.empty?

      if dep_types.include?('devDependencies') &&
          dep_types.include?('dependencies') &&
          dep_types.include?('optionalDependencies')
        report_error("No dependencies were scanned!")
        return ''
      elsif dep_types.include?('devDependencies') && dep_types.include?('dependencies')
        report_warn(:scanner_misconfiguration, "Scanning only optionalDependencies!")
      end

      command = ' --groups '
      command << 'dependencies ' unless dep_types.include?('dependencies')
      command << 'devDependencies ' unless dep_types.include?('devDependencies')
      command << 'optionalDependencies ' unless dep_types.include?('optionalDependencies')
    end

    # severity and vuln title in the yarn output looks like
    # | low           | Prototype Pollution                                          |
    # which are stored in the vuln hash as "low" ==> "Prototype Pollution"
    # need to update that to
    #     1) "severity" => "low"
    #     2) "title" => "Prototype Pollution"
    #
    # Also, add a separate id field
    def normalize_vuln(vuln)
      sev_levels = %w[info low moderate high critical]

      sev_levels.each do |sev|
        if vuln[sev]
          vuln['Severity'] = sev
          vuln['Title'] = vuln[sev]
          vuln.delete(sev)
          break
        end
      end

      # "More info" looks like https://www.npmjs.com/advisories/1179
      # need to extract the id at the end
      id = vuln["More info"].split("https://www.npmjs.com/advisories/")[1]
      vuln['ID'] = id.to_i
    end

    def format_vulns(vulns)
      str = ""
      vulns.each do |vul|
        vul.each do |k, v|
          str += "#{k}: #{v}\n"
        end
        str += "\n"
      end
      str
    end
  end
end
