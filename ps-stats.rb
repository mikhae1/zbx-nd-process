#!/usr/bin/env ruby
=begin
Process crash monitor. Optimized for Zabbix.

Script monitors selected process restarts including children if found.
All statistics are saved to cache file.

Requirements:
  Ruby 1.9.x
=end

require 'optparse'
require 'yaml'
require 'time'

CACHE_TTL = 55

def main
  options = {}
  optparse = OptionParser.new do |opts|
    opts.banner = "Usage: #{$0} [options]"

    opts.on("-k", "--key keyname", String, "Return specific key value") do |p|
      options[:key] = p
    end

    opts.on("-f", "--pidfile /path/to/pidfile", String, "Parent process PID File") do |p|
      options[:pidfile] = p
    end

    opts.on("-p", "--pid PID", OptionParser::DecimalInteger, "Parent process PID") do |p|
      options[:pid] = p
    end

    opts.on("-s", "--systemd service.name", String, "Systemd service.name") do |p|
      options[:systemd] = p
    end

    opts.on("-g", "--grep string", String, "String to grep in `ps` output") do |p|
      options[:grep] = p
    end

    opts.on("-c", "--cache /path/to/file", String, "Cache file path") do |p|
      options[:cache] = p
    end

    opts.on_tail("-h", "--help", "Display this message") do
      puts opts
      exit
    end
  end

  begin
    optparse.parse!

    if options[:pidfile].nil? && options[:pid].nil? &&
      options[:systemd].nil? && options[:grep].nil?
        raise OptionParser::MissingArgument.new(
          "You should specify PID of the running process!\n"\
          "Provide one of the parameters: [pidfile, pid, systemd, grep]")
    end
  rescue OptionParser::InvalidOption, OptionParser::MissingArgument
    puts $!.to_s
    puts optparse
    exit
  end

  stats = {
    parent_pid: nil,
    parent_restart_count:  0,
    child_count: 0,
    child_crash_count: 0,
    child_pids: [],
    params: {}
  }

  if options[:pid]
    p_pid = options[:pid]
    stats[:params][:pid] = options[:pid]
  elsif options[:pidfile]
    p_pid = File.read(options[:pidfile]).strip()
    stats[:params][:pidfile] = options[:pidfile]
  elsif options[:systemd]
    p_pid = `systemctl status #{options[:systemd]} |
      grep 'Main PID' | grep -o '[0-9]*'`
    stats[:params][:systemd] = options[:systemd]
  elsif options[:grep]
    p_pid = `ps aux | grep '#{options[:grep]}' | grep -v 'grep' |
      grep -v '#{$0}' | awk '{print $2}' | tail -1`
     stats[:params][:grep] = options[:grep]
  end

  begin
    p_pid = Integer(p_pid)
    Process.getpgid(p_pid)
  rescue Errno::ESRCH, ArgumentError
    raise "No process is running with PID: #{p_pid}"
  end

  c_pids = `pgrep -P #{p_pid}`.split()

  if !p_pid then
    raise "Can't read parent pid: parent #{p_pid}, children: #{c_pids}"
  elsif !c_pids.any? then
    puts "WARN: Can't find children pids: parent #{p_pid}"
  end

  stats_path = options[:cache]
  if !stats_path
    stats_path = File.join('./', File.basename($0, '.rb') + '-cache.yml')
  end

  save_stats = ->() {
    stats[:parent_pid] = p_pid
    stats[:child_pids] = c_pids
    stats[:child_count] = c_pids.length
    File.open(stats_path, 'w') {|f| YAML.dump(stats, f) }
  }

  if !File.file?(stats_path)
    save_stats.call()
  end

  data = YAML.load_file(stats_path);

  if File.mtime(stats_path) + CACHE_TTL > DateTime.now.to_time
    stats = data
  else
    stats = update_stats(data, p_pid, c_pids)
    save_stats.call()
  end

  if options[:key]
    puts stats[options[:key].to_sym]
  else
    puts stats
  end
end

def update_stats(_stats, p_pid, c_pids)
  p_restarted = false
  stats = _stats.clone()

  if stats[:parent_pid] != p_pid then
    # restart via systemctl restart
    p_restarted = true;
    stats[:parent_restart_count] += 1
  end

  if c_pids.any? then # single mode run
    if stats[:child_pids].length == c_pids.length then
      diff = diff_count(stats[:child_pids], c_pids)
      if c_pids.length > 0 && diff == c_pids.length then
        # reload via SIGUSR2
        if !p_restarted then
          p_restarted = true
          stats[:parent_restart_count] += 1
        end
      elsif diff != 0
        # children crash
        stats[:child_crash_count] += diff
      end
    elsif stats[:child_pids].length < c_pids.length then
      # new children were born after reload
      if stats[:child_pids].any? then
        stats[:parent_restart_count] += c_pids.length / stats[:child_pids].length - 1
      end

      # look for crashed childs
      expected_diff = c_pids.length - stats[:child_pids].length
      actual_diff = diff_count(stats[:child_pids], c_pids)
      if actual_diff > expected_diff
        stats[:child_crash_count] += actual_diff - expected_diff
      end
    elsif stats[:child_pids].length > c_pids.length then
      # old children were died after reload

      # look for crashed childs
      expected_diff = stats[:child_pids].length - c_pids.length
      actual_diff = diff_count(stats[:child_pids], c_pids)
      if actual_diff > expected_diff
        stats[:child_crash_count] += actual_diff - expected_diff
      end
    end
  end

  return stats
end

# returns number of non equal elements
def diff_count(arr1, arr2)
  eq = 0
  for a in arr1 do
    for b in arr2 do
      if a == b then
        eq += 1
        break
      end
    end
  end

  if arr1.length > arr2.length
    longest = arr1
  else
    longest = arr2
  end

  return longest.length - eq
end

main
